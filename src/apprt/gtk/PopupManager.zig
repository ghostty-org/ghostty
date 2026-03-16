const std = @import("std");
const Allocator = std.mem.Allocator;

const glib = @import("glib");
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
    /// Parallel to window_names/window_refs: true if the profile config
    /// changed since the window was created. Stale windows are destroyed
    /// and recreated on next toggle when hidden.
    window_stale: std.ArrayListUnmanaged(bool) = .empty,

    pub fn init(alloc: Allocator) PopupManager {
        return .{
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *PopupManager) void {
        for (self.profile_names.items) |name| self.alloc.free(name);
        for (self.profiles.items) |profile| {
            if (profile.keybind) |kb| self.alloc.free(kb);
            if (profile.command) |cmd| self.alloc.free(cmd);
            if (profile.cwd) |cwd| self.alloc.free(cwd);
        }
        self.profile_names.deinit(self.alloc);
        self.profiles.deinit(self.alloc);

        for (self.window_names.items) |name| self.alloc.free(name);
        self.window_names.deinit(self.alloc);
        self.window_refs.deinit(self.alloc);
        self.window_stale.deinit(self.alloc);
    }

    /// Load popup profiles from the config. This replaces any previously
    /// stored profiles. It does NOT destroy existing windows -- those will
    /// be lazily cleaned up on next toggle/show/hide.
    pub fn loadConfig(self: *PopupManager, config: *const configpkg.Config) void {
        // Free old name strings AND profile string fields since we own them
        for (self.profile_names.items) |name| self.alloc.free(name);
        for (self.profiles.items) |profile| {
            if (profile.keybind) |kb| self.alloc.free(kb);
            if (profile.command) |cmd| self.alloc.free(cmd);
            if (profile.cwd) |cwd| self.alloc.free(cwd);
        }
        self.profile_names.clearRetainingCapacity();
        self.profiles.clearRetainingCapacity();

        for (config.popup.names.items, config.popup.profiles.items) |name, profile| {
            const duped = self.alloc.dupeZ(u8, name) catch |err| {
                log.warn("failed to duplicate popup profile name: {}", .{err});
                continue;
            };

            // Deep-copy the profile so we own the string fields (cwd, command).
            // The config may be freed after loadConfig returns, so borrowing
            // slices from it would be a use-after-free.
            var owned_profile = profile;
            if (profile.command) |cmd| {
                owned_profile.command = self.alloc.dupe(u8, cmd) catch |err| {
                    log.warn("failed to duplicate popup command: {}", .{err});
                    self.alloc.free(duped);
                    continue;
                };
            }
            if (profile.cwd) |cwd| {
                owned_profile.cwd = self.alloc.dupe(u8, cwd) catch |err| {
                    log.warn("failed to duplicate popup cwd: {}", .{err});
                    if (owned_profile.command) |cmd| self.alloc.free(cmd);
                    self.alloc.free(duped);
                    continue;
                };
            }
            if (profile.keybind) |kb| {
                owned_profile.keybind = self.alloc.dupe(u8, kb) catch |err| {
                    log.warn("failed to duplicate popup keybind: {}", .{err});
                    if (owned_profile.command) |cmd| self.alloc.free(cmd);
                    if (owned_profile.cwd) |cwd| self.alloc.free(cwd);
                    self.alloc.free(duped);
                    continue;
                };
            }

            self.profile_names.append(self.alloc, duped) catch |err| {
                log.warn("failed to store popup profile name: {}", .{err});
                if (owned_profile.keybind) |kb| self.alloc.free(kb);
                if (owned_profile.command) |cmd| self.alloc.free(cmd);
                if (owned_profile.cwd) |cwd| self.alloc.free(cwd);
                self.alloc.free(duped);
                continue;
            };
            self.profiles.append(self.alloc, owned_profile) catch |err| {
                log.warn("failed to store popup profile: {}", .{err});
                if (self.profile_names.pop()) |popped| {
                    const plain: []const u8 = popped;
                    self.alloc.free(plain);
                }
                if (owned_profile.keybind) |kb| self.alloc.free(kb);
                if (owned_profile.command) |cmd| self.alloc.free(cmd);
                if (owned_profile.cwd) |cwd| self.alloc.free(cwd);
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
                // If stale (config changed), destroy and recreate
                if (self.isWindowStale(name)) {
                    self.destroyWindow(name);
                    return self.createAndShow(name);
                }
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
            // If stale (config changed), destroy and recreate
            if (self.isWindowStale(name)) {
                self.destroyWindow(name);
                return self.createAndShow(name);
            }
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

    /// Update popup profiles from a new config. Handles:
    /// - Removed profiles: destroy any running popup window immediately
    /// - New profiles: stored for lazy creation on next toggle/show
    /// - Changed profiles: stored config updated; visible popups keep
    ///   running. Windows are marked stale so the next toggle cycle
    ///   (hide→show) destroys and recreates them with new config.
    pub fn updateProfileConfigs(self: *PopupManager, config: *const configpkg.Config) void {
        // 1. Destroy windows for truly removed profiles only
        var i: usize = 0;
        while (i < self.window_names.items.len) {
            const wname = self.window_names.items[i];
            const still_exists = for (config.popup.names.items) |cname| {
                if (std.mem.eql(u8, wname, cname)) break true;
            } else false;

            if (!still_exists) {
                if (self.window_refs.items[i].get()) |win| {
                    defer win.unref();
                    win.as(gtk.Window).destroy();
                }
                self.removeWindowAt(i);
            } else {
                i += 1;
            }
        }

        // IMPORTANT: markStaleIfChanged must run BEFORE loadConfig because it
        // reads old profile string fields (cwd, command, keybind) that loadConfig
        // will free and replace. Reordering these steps causes use-after-free.
        // 2. Mark existing windows as stale — they'll be destroyed and
        //    recreated on next toggle if hidden, or kept alive if visible
        //    until the user toggles them.
        for (self.window_names.items) |wname| {
            self.markStaleIfChanged(wname, config);
        }

        // 3. Reload stored profiles from new config
        self.loadConfig(config);
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
        self.window_stale.clearRetainingCapacity();
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
        const profile = self.getProfile(name) orelse {
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
            if (self.window_names.pop()) |popped_name| {
                const plain: []const u8 = popped_name;
                self.alloc.free(plain);
            }
            win.as(gtk.Window).destroy();
            return false;
        };
        self.window_stale.append(self.alloc, false) catch |err| {
            log.warn("failed to track popup stale flag: {}", .{err});
            if (self.window_names.pop()) |popped_name| {
                const plain: []const u8 = popped_name;
                self.alloc.free(plain);
            }
            _ = self.window_refs.pop();
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

        // Resolve working directory: explicit cwd > focused surface pwd > none.
        // Track ownership so we only free allocations we made (not borrows from
        // surface.getPwd() which is managed by the surface).
        var wd_owned: bool = false;
        const working_directory: ?[:0]const u8 = wd: {
            if (profile.cwd) |cwd| {
                wd_owned = true;
                // Only expand bare ~ or ~/... (not ~otheruser)
                if (cwd.len == 1 and cwd[0] == '~' or
                    (cwd.len > 1 and cwd[0] == '~' and cwd[1] == '/'))
                {
                    if (std.posix.getenv("HOME")) |home| {
                        break :wd std.fmt.allocPrintSentinel(
                            self.alloc,
                            "{s}{s}",
                            .{ home, cwd[1..] },
                            0,
                        ) catch break :wd null;
                    }
                }
                break :wd self.alloc.dupeZ(u8, cwd) catch break :wd null;
            }
            // Try to inherit from focused surface (borrowed, not owned)
            const list = gtk.Window.listToplevels();
            defer list.free();
            var node_: ?*glib.List = list;
            while (node_) |node| : (node_ = node.f_next) {
                const gtk_window: *gtk.Window = @ptrCast(@alignCast(node.f_data orelse continue));
                if (gtk_window.isActive() == 0) continue;
                const ghostty_win = gobject.ext.cast(Window, gtk_window) orelse continue;
                const surface = ghostty_win.getActiveSurface() orelse continue;
                break :wd surface.getPwd();
            }
            break :wd null;
        };
        defer if (wd_owned) {
            if (working_directory) |wd| self.alloc.free(wd);
        };

        // Create initial tab
        win.newTabForWindow(null, .{
            .working_directory = working_directory,
            .background_opacity = profile.opacity,
        });

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
        _ = self.window_stale.orderedRemove(idx);
        // Cast sentinel-terminated slice to plain slice for Allocator.free
        const plain: []const u8 = name;
        self.alloc.free(plain);
    }

    /// Check if a tracked window is marked stale (config changed since creation).
    fn isWindowStale(self: *const PopupManager, name: []const u8) bool {
        const idx = self.findWindowIndex(name) orelse return false;
        return self.window_stale.items[idx];
    }

    /// Mark a window stale if its profile differs from the new config.
    /// Compares the stored (old) profile against the new config's profile
    /// for the same name. Uses field-by-field comparison for non-string
    /// fields and content comparison for string fields.
    fn markStaleIfChanged(self: *PopupManager, name: []const u8, config: *const configpkg.Config) void {
        const win_idx = self.findWindowIndex(name) orelse return;
        const old_profile = self.getProfile(name) orelse return;

        // Find the new profile in config
        for (config.popup.names.items, config.popup.profiles.items) |cname, new_profile| {
            if (std.mem.eql(u8, name, cname)) {
                // Compare all fields — non-string enums/ints/bools
                if (old_profile.position != new_profile.position or
                    old_profile.anchor != new_profile.anchor or
                    !optionalDimensionEqual(old_profile.x, new_profile.x) or
                    !optionalDimensionEqual(old_profile.y, new_profile.y) or
                    old_profile.width.value != new_profile.width.value or
                    old_profile.width.unit != new_profile.width.unit or
                    old_profile.height.value != new_profile.height.value or
                    old_profile.height.unit != new_profile.height.unit or
                    old_profile.autohide != new_profile.autohide or
                    old_profile.persist != new_profile.persist or
                    !optionalF64Equal(old_profile.opacity, new_profile.opacity) or
                    !optionalSliceEqual(old_profile.command, new_profile.command) or
                    !optionalSliceEqual(old_profile.cwd, new_profile.cwd) or
                    !optionalSliceEqual(old_profile.keybind, new_profile.keybind))
                {
                    self.window_stale.items[win_idx] = true;
                    return;
                }
                return; // Not changed
            }
        }
    }

    /// Destroy a tracked popup window by name.
    fn destroyWindow(self: *PopupManager, name: []const u8) void {
        const idx = self.findWindowIndex(name) orelse return;
        if (self.window_refs.items[idx].get()) |win| {
            defer win.unref();
            win.as(gtk.Window).destroy();
        }
        self.removeWindowAt(idx);
    }

    fn getProfile(self: *const PopupManager, name: []const u8) ?popupmod.PopupProfile {
        for (self.profile_names.items, self.profiles.items) |n, p| {
            if (std.mem.eql(u8, n, name)) return p;
        }
        return null;
    }
};

fn optionalDimensionEqual(a: ?popupmod.Dimension, b: ?popupmod.Dimension) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.value == b.?.value and a.?.unit == b.?.unit;
}

fn optionalSliceEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn optionalF64Equal(a: ?f64, b: ?f64) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}
