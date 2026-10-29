//! State for a single tmux control mode (`tmux -CC`) connection.
//!
//! The surface that saw the DCS 1000p sequence is the "gateway". It owns
//! the pty that speaks the control protocol and shows the control plate
//! (the command menu, logging output and the command prompt); it never
//! shows a tmux pane itself.
//!
//! Every tmux pane is mirrored by a "follower" surface. A follower has no
//! pty of its own: its input becomes `send-keys` on the gateway and its
//! output is fed to it from the `%output` notifications the gateway
//! receives. Panes, windows and splits are owned by the tmux server, so
//! GUI actions are translated into tmux commands and the resulting
//! notifications are what actually build the native tabs and splits.
//!
//! The gateway's stream handler runs the viewer (`terminal.tmux.Viewer`)
//! on the pty read thread. The viewer parses notifications, owns a
//! strictly sequential command queue and matches tmux's replies to
//! commands by position. Its actions reach the gateway surface as surface
//! messages, which call into this session on the app thread. Every command
//! goes through that queue (`sendCommand`). Only detach and force-quit
//! write past it (`sendRaw`), because by then the viewer no longer sends
//! commands.
//!
//! Where the apprt can create a surface for a given pane (`native_layout`,
//! true when its surface has `tmuxPane`),
//! `mirror` sends one spec per tmux window with its whole binary pane tree
//! (see `tmux_mirror`), the zoomed and focused panes, the title and the
//! tab position. An empty tree is the only way a tab is closed. Every
//! surface the apprt creates for a leaf names the pane it is for and
//! claims exactly that pane (`canClaim`), which rejects a pane from an
//! earlier attach, from another window, or one that already has a
//! follower. A pane that moves to another window is released and recreated
//! there (`releaseMisplaced`); surfaces are never reparented across tabs.
//! Other apprts use the sequential path instead, where each new surface
//! adopts the next pane that has no follower yet.
//!
//! tmux owns the pane grids. A follower's grid comes from the layout, and
//! resizing its surface never resizes its pane. The tab owns the window
//! size: the apprt reports the tab's size, the core turns it into cells
//! with the follower's cell size and padding, and `sizeWindow` sends
//! `refresh-client -C @<window>:<cols>x<rows>`. `resize-window` is not used
//! here because it pins the window's `window-size`. A divider drag becomes
//! one `resize-pane`; when no single `resize-pane` can express it, the
//! layout is sent again so the divider snaps back.
//!
//! Tab and pane selection go to tmux as `select-window` and `select-pane`.
//! `tmux_mirror.Selection` remembers the requests tmux hasn't confirmed
//! yet, so a report that only echoes our own request is not applied
//! again and a stale one is ignored.
//!
//! Which tmux windows share a native window is kept in the `@affinities`
//! session option (`syncAffinities`). tmux sends no notification for
//! `swap-window`, so the viewer subscribes to the window order and the
//! session lists the windows again after its own reorders.
//!
//! Detaching always sends `detach-client` first and then closes every
//! mirrored tab, leaving the tmux session running. `%exit` and the death
//! of the tmux server run the same teardown. A follower that closes while
//! its pane is still mapped kills that pane, so anything closed on tmux's
//! behalf is released (`releaseSurface`) first.

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("apprt.zig");
const global = @import("global.zig");
const renderer = @import("renderer.zig");
const termio = @import("termio.zig");
const terminal = @import("terminal/main.zig");
const tmux_mirror = @import("tmux_mirror.zig");
const Surface = @import("Surface.zig");
const Layout = terminal.tmux.Layout;
const Snapshot = terminal.tmux.Snapshot;
const TmuxWindow = apprt.action.TmuxWindow;

const log = std.log.scoped(.tmux_session);

/// Whether the apprt mirrors every tmux window as a whole native tab
/// (`apprt.Action.tmux_window`) and tells new surfaces which pane they
/// are for. Otherwise panes are created one split at a time and the next
/// surface to be created adopts the next missing pane (`advance`).
///
/// This is decided at compile time so that an apprt with native tabs never
/// takes the pane-at-a-time path, whose single pending pane races with
/// asynchronous surface creation.
pub const native_layout = @hasDecl(apprt.runtime.Surface, "tmuxPane");

/// Counts attaches. See `Session.attach`.
var attaches: u64 = 0;

/// The most panes we'll create surfaces for in a single pass. This only
/// exists so that a bug (or an apprt that fails to create surfaces) can't
/// spin forever; real sessions are far below it.
const max_advance = 256;

pub const Session = struct {
    alloc: Allocator,

    /// The gateway surface. Owns the control pty.
    leader: *Surface,

    /// The panes we mirror, in both directions.
    pane_to_surface: std.AutoHashMapUnmanaged(usize, *Surface) = .empty,
    surface_to_pane: std.AutoHashMapUnmanaged(u64, usize) = .empty,

    /// The window each pane belongs to, from the most recent layout.
    pane_window: std.AutoHashMapUnmanaged(usize, usize) = .empty,

    /// The panes we've already asked tmux for the existing contents of.
    captured: std.AutoHashMapUnmanaged(usize, void) = .empty,

    /// The most recent layout tmux told us about. Owned by us.
    layout: ?*Snapshot = null,

    /// The pane the next surface we create should adopt. Surfaces created
    /// while this is set become followers instead of spawning a shell.
    pending: ?usize = null,

    /// Guard so that a surface registering itself from inside `advance`
    /// doesn't recurse back into it.
    advancing: bool = false,

    /// Accumulated input for the "C" command prompt, or null when we're
    /// not prompting.
    prompt: ?std.ArrayList(u8) = null,

    /// Native-window grouping of tmux windows, stored in the `@affinities`
    /// session option (the same option iTerm2 uses, so both clients agree
    /// on the grouping). Each inner list is the set of tmux window ids
    /// that share one native window as tabs.
    affinities: std.ArrayList(std.ArrayList(usize)) = .empty,

    /// When the user creates a tab (`new_tab`), the next tmux window
    /// joins this window's affinity group.
    pending_affinity: ?usize = null,

    /// Whether `detach` has already asked tmux to let us go. Once the tmux
    /// client exits, another `detach-client` would be typed into the shell
    /// that started it.
    detached: bool = false,

    /// On the sequential path, a follower registered and the session can
    /// create the next pane on the next app tick (see `advance`).
    advance_pending: bool = false,

    /// Tmux's active window id, from the select-pane we send on focus and
    /// from `%window-pane-changed` notifications (including an external
    /// `select-window`). `new_tab` prefers this so affinity stays correct
    /// when native focus lags behind across windows.
    active_window: ?usize = null,

    /// Last `set @affinities` payload we sent, to avoid spamming tmux.
    last_affinities: ?[]u8 = null,

    /// Ghostty's own new_window asked for the next tmux window to get a
    /// native window of its own. Every other new window joins the native
    /// window of the current one (see syncAffinities).
    pending_new_group: bool = false,

    // The fields below are only used with `native_layout`.

    /// Identifies this attach in the tabs we mirror, so that tabs and
    /// surfaces left over from an earlier attach never match.
    attach: u64,

    /// Increases with every window spec we send.
    spec_serial: u64 = 0,

    /// The tmux windows we mirror as native tabs, and the serial of the
    /// spec that last updated each tab.
    mirrored: std.AutoHashMapUnmanaged(usize, u64) = .empty,

    /// The window whose tab each pane was last sent to. When a pane shows
    /// up in another window its surface has to be recreated there.
    placed: std.AutoHashMapUnmanaged(usize, usize) = .empty,

    /// The terminal grid last given to the follower of each pane.
    grids: std.AutoHashMapUnmanaged(usize, renderer.GridSize) = .empty,

    /// The current window and active pane, without echoes.
    selection: tmux_mirror.Selection = .{},

    /// The size we last gave each window with `refresh-client -C`. tmux
    /// sizes a window that has none at the client size, which we never
    /// set, so every window of a native window is given the size of the
    /// tab that is shown there.
    window_sizes: std.AutoHashMapUnmanaged(usize, renderer.GridSize) = .empty,

    /// Whether we subscribed to the order of the windows. See
    /// `terminal.tmux.Viewer.windows_subscription_command`.
    subscribed: bool = false,

    pub fn init(alloc: Allocator, leader: *Surface) Session {
        attaches += 1;
        return .{ .alloc = alloc, .leader = leader, .attach = attaches };
    }

    pub fn deinit(self: *Session) void {
        self.pane_to_surface.deinit(self.alloc);
        self.surface_to_pane.deinit(self.alloc);
        self.pane_window.deinit(self.alloc);
        self.captured.deinit(self.alloc);
        if (self.layout) |v| v.destroy();
        if (self.prompt) |*v| v.deinit(self.alloc);
        for (self.affinities.items) |*group| group.deinit(self.alloc);
        self.affinities.deinit(self.alloc);
        if (self.last_affinities) |v| self.alloc.free(v);
        self.mirrored.deinit(self.alloc);
        self.placed.deinit(self.alloc);
        self.grids.deinit(self.alloc);
        self.window_sizes.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn isLeader(self: *const Session, surface: *const Surface) bool {
        return self.leader == surface;
    }

    pub fn isFollower(self: *const Session, surface: *const Surface) bool {
        return self.surface_to_pane.contains(surface.id);
    }

    /// True once we're mirroring at least one pane. Before this the
    /// gateway still forwards typing to tmux; after it the gateway is
    /// control-only because the followers own their panes.
    pub fn hasFollowers(self: *const Session) bool {
        return self.pane_to_surface.count() > 0;
    }

    pub fn surfaceForPane(self: *const Session, pane_id: usize) ?*Surface {
        return self.pane_to_surface.get(pane_id);
    }

    pub fn paneForSurface(self: *const Session, surface: *const Surface) ?usize {
        return self.surface_to_pane.get(surface.id);
    }

    /// True if the surface being created right now should be a follower.
    pub fn shouldCreateFollower(self: *const Session) bool {
        return self.pending != null;
    }

    /// Claim the pane id reserved for the surface being created.
    pub fn takePane(self: *Session) ?usize {
        defer self.pending = null;
        return self.pending;
    }

    pub fn registerPane(self: *Session, pane_id: usize, surface: *Surface) void {
        self.pane_to_surface.put(self.alloc, pane_id, surface) catch |err| {
            log.warn("failed to map tmux pane err={}", .{err});
            return;
        };
        self.surface_to_pane.put(self.alloc, surface.id, pane_id) catch |err| {
            log.warn("failed to map tmux surface err={}", .{err});
            _ = self.pane_to_surface.remove(pane_id);
            return;
        };
    }

    /// Whether a surface created for `pane` may become its follower: the
    /// pane is still in the window whose tab the surface was created in,
    /// in this attach, and has no follower yet.
    pub fn canClaim(self: *const Session, pane: TmuxWindow.Pane) bool {
        if (pane.session != self.attach) return false;
        const window = self.pane_window.get(pane.pane) orelse return false;
        if (window != pane.window) return false;
        return !self.pane_to_surface.contains(pane.pane);
    }

    /// The terminal grid tmux gives a pane in the last layout.
    pub fn paneGrid(self: *const Session, pane_id: usize) ?renderer.GridSize {
        const snapshot = self.layout orelse return null;
        const window_id = self.pane_window.get(pane_id) orelse return null;
        const window = snapshot.findWindow(window_id) orelse return null;
        return findPaneGrid(
            window.layout,
            if (window.zoomed) window.visible_layout else null,
            pane_id,
        );
    }

    /// A follower finished initializing at the grid `paneGrid` gave it.
    /// Fill it with what is already on the pane.
    pub fn paneRegistered(self: *Session, pane_id: usize, grid: ?renderer.GridSize) void {
        if (grid) |v| self.grids.put(self.alloc, pane_id, v) catch |err| {
            log.warn("failed to track tmux pane grid err={}", .{err});
        };
        self.capturePane(pane_id);
    }

    /// Forget a follower without telling tmux anything: its pane lives on,
    /// in another window or not at all. The surface goes away with the tab
    /// that no longer holds it, and with nothing mapped it doesn't send
    /// `kill-pane` when it does.
    ///
    /// Unlike `unregisterSurface` this keeps the pane's window, which still
    /// describes the current layout.
    pub fn releaseSurface(self: *Session, surface: *Surface) void {
        const kv = self.surface_to_pane.fetchRemove(surface.id) orelse return;
        const pane_id = kv.value;
        _ = self.pane_to_surface.remove(pane_id);
        _ = self.captured.remove(pane_id);
        _ = self.grids.remove(pane_id);
        _ = self.placed.remove(pane_id);
        surface.tmux_grid = null;
    }

    pub fn unregisterSurface(self: *Session, surface: *Surface) void {
        if (self.surface_to_pane.fetchRemove(surface.id)) |kv| {
            const pane_id = kv.value;
            const window_id = self.pane_window.get(pane_id);
            _ = self.pane_to_surface.remove(pane_id);
            _ = self.captured.remove(pane_id);
            _ = self.pane_window.remove(pane_id);
            _ = self.grids.remove(pane_id);
            _ = self.placed.remove(pane_id);

            // Closing the last native surface for a tmux window drops it
            // from @affinities right away rather than on the next
            // list-windows, so a tab opened in between can't join it.
            if (window_id) |wid| {
                if (!self.windowHasSurface(wid)) {
                    self.removeWindowFromAffinities(wid);
                    self.saveAffinities();
                }
            }
        }
    }

    fn windowHasSurface(self: *const Session, window_id: usize) bool {
        var it = self.pane_window.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != window_id) continue;
            if (self.pane_to_surface.contains(entry.key_ptr.*)) return true;
        }
        return false;
    }

    fn removeWindowFromAffinities(self: *Session, window_id: usize) void {
        var gi: usize = 0;
        while (gi < self.affinities.items.len) {
            const group = &self.affinities.items[gi];
            var ii: usize = 0;
            while (ii < group.items.len) {
                if (group.items[ii] == window_id) {
                    _ = group.orderedRemove(ii);
                    continue;
                }
                ii += 1;
            }
            if (group.items.len == 0) {
                var removed = self.affinities.orderedRemove(gi);
                removed.deinit(self.alloc);
                continue;
            }
            gi += 1;
        }
    }

    //---------------------------------------------------------------
    // Commands

    /// Queue a tmux command on the gateway pty. The command must include
    /// its trailing newline. This goes through the IO thread so that it
    /// can be interleaved with the viewer's own command queue.
    pub fn sendCommand(self: *Session, command: []const u8) void {
        if (command.len == 0) return;
        log.debug("send {s}", .{std.mem.trimEnd(u8, command, "\n")});
        const data = self.alloc.dupe(u8, command) catch |err| {
            log.warn("failed to allocate tmux command err={}", .{err});
            return;
        };

        self.leader.io.queueMessage(.{ .tmux_command = .{
            .alloc = self.alloc,
            .data = data,
        } }, .unlocked);
    }

    /// Write bytes to the gateway pty past the viewer's command queue
    /// (`termio.Message.tmux_raw`). Only for detach and force-quit: the
    /// viewer stops sending commands once we detach, so a queued
    /// `tmux_command` would never reach tmux.
    ///
    /// The viewer stops matching replies against its queue first, since
    /// tmux answers these writes too and their blocks would otherwise be
    /// taken as replies to whatever the viewer has in flight.
    pub fn sendRaw(self: *Session, command: []const u8) void {
        if (command.len == 0) return;
        const data = self.alloc.dupe(u8, command) catch |err| {
            log.warn("failed to allocate tmux raw write err={}", .{err});
            return;
        };

        self.leader.io.queueMessage(.{ .tmux_detaching = {} }, .unlocked);
        self.leader.io.queueMessage(.{ .tmux_raw = .{
            .alloc = self.alloc,
            .data = data,
        } }, .unlocked);
    }

    /// Format and queue a tmux command. The format must produce the
    /// trailing newline.
    pub fn sendCommandFmt(
        self: *Session,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        var stack_buf: [256]u8 = undefined;
        var stack: std.heap.BufferFirstAllocator = .init(&stack_buf, self.alloc);
        const alloc = stack.allocator();
        const command = std.fmt.allocPrint(alloc, fmt, args) catch |err| {
            log.warn("failed to format tmux command err={}", .{err});
            return;
        };
        defer alloc.free(command);
        self.sendCommand(command);
    }

    /// Print text on the gateway terminal without sending anything to
    /// tmux. Used for the control plate.
    pub fn echo(self: *Session, text: []const u8) void {
        if (text.len == 0) return;
        const data = self.alloc.dupe(u8, text) catch |err| {
            log.warn("failed to allocate tmux echo err={}", .{err});
            return;
        };

        self.leader.io.queueMessage(.{ .tmux_echo = .{
            .alloc = self.alloc,
            .data = data,
        } }, .unlocked);
    }

    /// Send raw terminal bytes to a pane as tmux keys. If `pane_id` is
    /// null the session's active pane is targeted. See
    /// `terminal.tmux.writeSendKeys` for the encoding.
    pub fn sendKeys(self: *Session, pane_id: ?usize, data: []const u8) void {
        var stack_buf: [512]u8 = undefined;
        var stack: std.heap.BufferFirstAllocator = .init(&stack_buf, self.alloc);
        var buf: std.Io.Writer.Allocating = .init(stack.allocator());
        defer buf.deinit();

        var rest = data;
        while (rest.len > 0) {
            const chunk = rest[0..@min(rest.len, terminal.tmux.send_keys_max)];
            rest = rest[chunk.len..];

            buf.clearRetainingCapacity();
            terminal.tmux.writeSendKeys(&buf.writer, pane_id, chunk) catch {
                log.warn("failed to encode tmux send-keys", .{});
                return;
            };
            self.sendCommand(buf.writer.buffered());
        }
    }

    /// Tell tmux that the view of a pane changed size.
    ///
    /// A pane can't be sized past the window that holds it, so a window
    /// we show as a single surface is sized with `resize-window`. That
    /// also takes the window off tmux's automatic sizing, which is what
    /// we want here: every tmux window gets its own native tab and
    /// they aren't all the same size. `detach` puts that back.
    ///
    /// Once a window has splits the surface is only part of it, so all
    /// we can do (and all that makes sense) is move the divider.
    pub fn resizePane(
        self: *Session,
        pane_id: usize,
        columns: usize,
        rows: usize,
    ) void {
        if (columns == 0 or rows == 0) return;

        if (self.pane_window.get(pane_id)) |window| {
            if (self.windowPaneCount(window) > 1) {
                self.sendCommandFmt("resize-pane -t %{d} -x {d} -y {d}\n", .{
                    pane_id,
                    columns,
                    rows,
                });
            } else {
                self.sendCommandFmt(
                    "resize-window -t @{d} -x {d} -y {d}\n",
                    .{ window, columns, rows },
                );
            }
        } else {
            // No layout yet, so the client size is all we have.
            self.sendCommandFmt(
                "refresh-client -C {d},{d}\n",
                .{ columns, rows },
            );
        }

        self.capturePane(pane_id);
    }

    /// Detach from tmux, leaving the session the way we found it.
    ///
    /// Writes go out of band (`sendRaw`) so a following force-quit can't
    /// destroy the viewer before `detach-client` is flushed to the pty.
    pub fn detach(self: *Session) void {
        if (self.detached) return;
        self.detached = true;

        // Sizing a window by hand took it off tmux's automatic sizing,
        // and that would otherwise follow the session to its next
        // client. Native tabs never size windows by hand.
        if (comptime !native_layout) if (self.layout) |snapshot| {
            for (snapshot.windows) |window| {
                var stack_buf: [128]u8 = undefined;
                var stack: std.heap.BufferFirstAllocator = .init(&stack_buf, self.alloc);
                const alloc = stack.allocator();
                const command = std.fmt.allocPrint(
                    alloc,
                    "set-option -w -u -t @{d} window-size\n",
                    .{window.id},
                ) catch |err| {
                    log.warn("failed to format window-size unset err={}", .{err});
                    continue;
                };
                defer alloc.free(command);
                self.sendRaw(command);
            }
        };

        self.sendRaw("detach-client\n");
    }

    /// Ask tmux for what is already on a pane, once, so that a new view of
    /// it doesn't start out blank: `%output` only carries what happens
    /// from now on.
    ///
    /// This happens after the view has told tmux its size so that the
    /// contents and cursor we get back are for the size we show them at.
    fn capturePane(self: *Session, pane_id: usize) void {
        if (self.captured.contains(pane_id)) return;
        self.captured.put(self.alloc, pane_id, {}) catch |err| {
            log.warn("failed to track tmux capture err={}", .{err});
            return;
        };

        self.leader.io.queueMessage(
            .{ .tmux_capture_pane = pane_id },
            .unlocked,
        );
    }

    /// Ask tmux for the window list again, for a change it doesn't notify
    /// us about. The answer comes back as a new layout.
    pub fn refreshWindows(self: *Session) void {
        self.leader.io.queueMessage(.{ .tmux_refresh_windows = {} }, .unlocked);
    }

    /// How many panes a window holds, as of the last layout.
    fn windowPaneCount(self: *const Session, window_id: usize) usize {
        var count: usize = 0;
        var it = self.pane_window.valueIterator();
        while (it.next()) |v| {
            if (v.* == window_id) count += 1;
        }

        return count;
    }

    //---------------------------------------------------------------
    // Layout

    /// Take ownership of a new layout and reconcile the GUI with it.
    /// Must be called on the app thread.
    pub fn applyLayout(self: *Session, snapshot: *Snapshot) void {
        // Another session (after switch-client) has its own @affinities,
        // so what we know about the old one must not carry over.
        const switched = if (self.layout) |old|
            old.session_id != snapshot.session_id
        else
            false;
        if (self.layout) |old| old.destroy();
        self.layout = snapshot;
        if (switched) self.resetAffinities();

        if (self.affinities.items.len == 0 and snapshot.affinities.len > 0) {
            self.loadAffinities(snapshot.affinities);
        }

        // Rebuild the pane -> window index.
        self.pane_window.clearRetainingCapacity();
        for (snapshot.windows) |window| {
            self.indexPanes(window.id, window.layout);
        }

        // A session always has a window, so an empty list only means the
        // viewer is switching sessions. Syncing then would save an empty
        // @affinities into the session we're switching to.
        if (snapshot.windows.len > 0) self.syncAffinities();
        if (comptime native_layout) {
            // Tabs follow tmux's window order, which some commands change
            // without telling us. The subscription outlives a switch to
            // another session, so this happens once per attach, as soon
            // as the viewer takes commands.
            if (!self.subscribed and snapshot.windows.len > 0) {
                self.subscribed = true;
                self.sendCommand(terminal.tmux.Viewer.windows_subscription_command);
            }
            self.mirror();
        } else {
            self.closeStalePanes();
            self.advance();
        }
    }

    fn resetAffinities(self: *Session) void {
        for (self.affinities.items) |*group| group.deinit(self.alloc);
        self.affinities.clearRetainingCapacity();
        if (self.last_affinities) |v| self.alloc.free(v);
        self.last_affinities = null;
        self.pending_affinity = null;
        self.pending_new_group = false;
        self.active_window = null;
        self.selection = .{};
    }

    fn loadAffinities(self: *Session, raw: []const u8) void {
        var groups = std.mem.tokenizeAny(u8, raw, " |");
        while (groups.next()) |encoded| {
            const ids_text = if (std.mem.indexOfScalar(u8, encoded, ';')) |i|
                encoded[0..i]
            else
                encoded;
            var group: std.ArrayList(usize) = .empty;
            var ids = std.mem.tokenizeScalar(u8, ids_text, ',');
            while (ids.next()) |id_text| {
                const id = std.fmt.parseInt(usize, id_text, 10) catch continue;
                group.append(self.alloc, id) catch {
                    group.deinit(self.alloc);
                    return;
                };
            }
            if (group.items.len == 0) {
                group.deinit(self.alloc);
                continue;
            }
            self.affinities.append(self.alloc, group) catch {
                group.deinit(self.alloc);
                return;
            };
        }
        if (self.affinities.items.len > 0) {
            self.last_affinities = self.alloc.dupe(u8, raw) catch null;
        }
    }

    /// Remember which tmux window a forthcoming `new-window` should share
    /// a native window with (`new_tab`).
    pub fn noteTabAffinity(self: *Session, surface: *Surface) void {
        // With native layouts, native focus and tmux's selection are kept
        // in step, and the follower the action came from is in the native
        // window it was triggered in, which is also where `new-window -a`
        // places the window. Going by tmux's current window instead would
        // open the tab in another native window after focusing a window
        // whose pane tmux already had active.
        if (comptime native_layout) {
            if (self.paneForSurface(surface)) |pane| {
                if (self.pane_window.get(pane)) |window| {
                    self.pending_affinity = window;
                    return;
                }
            }
        }

        // Prefer tmux's active window when known. Native focus across
        // several windows can lag behind, while `select-window` and
        // `select-pane` still update tmux, and `new_tab` should follow
        // tmux.
        if (self.active_window) |wid| {
            self.pending_affinity = wid;
            return;
        }

        if (self.paneForSurface(surface)) |pane| {
            if (self.pane_window.get(pane)) |window| {
                self.pending_affinity = window;
                return;
            }
        }

        // The gateway has no pane: join the first live window.
        if (self.layout) |snapshot| {
            if (snapshot.windows.len > 0) {
                self.pending_affinity = snapshot.windows[0].id;
            }
        }
    }

    /// Ghostty's own new_window: the tmux window it creates gets a native
    /// window of its own rather than joining the current one.
    pub fn noteWindowAffinity(self: *Session) void {
        self.pending_affinity = null;
        self.pending_new_group = true;
    }

    /// tmux's current window changed. Bring it to the front, focused on
    /// the pane tmux has active in it.
    pub fn setActiveWindow(self: *Session, window_id: usize) void {
        if (comptime native_layout) {
            // Our own select-window is already shown, and reports that
            // were overtaken by it are stale.
            const show = self.selection.tmuxWindow(window_id, now());
            self.active_window = self.selection.current();
            if (self.layout) |snapshot| snapshot.setActiveWindow(
                self.active_window orelse window_id,
            );
            if (show) self.sendWindow(window_id, true);
            return;
        }

        self.active_window = window_id;
        if (self.layout) |snapshot| snapshot.setActiveWindow(window_id);

        const surface = surface: {
            if (self.layout) |snapshot| {
                if (snapshot.findWindow(window_id)) |window| {
                    if (self.pane_to_surface.get(window.active_pane)) |surface| {
                        break :surface surface;
                    }
                }
            }

            // We don't know the active pane yet (a window tmux announced
            // as current before listing it), so any of its panes will do.
            var it = self.pane_window.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* != window_id) continue;
                break :surface self.pane_to_surface.get(entry.key_ptr.*) orelse continue;
            }

            return;
        };

        _ = surface.rt_app.performAction(
            .{ .surface = surface },
            .present_terminal,
            {},
        ) catch |err| {
            log.warn("failed to present active tmux window err={}", .{err});
        };
    }

    /// The active pane of a tmux window changed. This is recorded but not
    /// shown: it doesn't make the window current, and focusing the pane
    /// here would answer our own `select-pane` (sent when a follower gains
    /// focus) by moving focus again.
    ///
    /// With native tabs the pane is focused, unless it is the echo of a
    /// native focus change: the tab of the window is updated so that the
    /// pane is focused whenever the tab is shown, and focused right away
    /// if the window is the current one.
    pub fn setActivePane(self: *Session, window_id: usize, pane_id: usize) void {
        if (comptime native_layout) {
            const show = self.selection.tmuxPane(window_id, pane_id, now());
            if (!show) return;
            const snapshot = self.layout orelse return;
            const window = snapshot.findWindow(window_id) orelse return;
            window.active_pane = pane_id;
            self.sendWindow(window_id, self.selection.current() == window_id);
            return;
        }

        // `new_tab` affinity follows the window the user last worked in,
        // which is where our select-pane on focus lands.
        self.active_window = window_id;
        const snapshot = self.layout orelse return;
        const window = snapshot.findWindow(window_id) orelse return;
        window.active_pane = pane_id;
    }

    /// A tmux window was renamed.
    pub fn renameWindow(self: *Session, window_id: usize, name: []const u8) void {
        const snapshot = self.layout orelse return;
        _ = snapshot.renameWindow(window_id, name) catch |err| {
            log.warn("failed to record tmux window name err={}", .{err});
            return;
        };

        // The tab title is the window name.
        if (comptime native_layout) self.sendWindow(window_id, false);
    }

    /// A follower gained focus. Tell tmux, unless the pane already is
    /// the active one as far as tmux knows: then this is focus following
    /// tmux and saying so would only echo.
    pub fn paneFocused(self: *Session, pane_id: usize) void {
        if (comptime native_layout) {
            const window_id = self.pane_window.get(pane_id) orelse return;
            const snapshot = self.layout orelse return;
            const window = snapshot.findWindow(window_id) orelse return;
            if (!self.selection.nativePane(
                window_id,
                pane_id,
                window.active_pane == pane_id,
                now(),
            )) return;
            window.active_pane = pane_id;
        }

        self.sendCommandFmt("select-pane -t %{d}\n", .{pane_id});
    }

    /// Keep `@affinities` in sync with the live window list and persist it.
    fn syncAffinities(self: *Session) void {
        const snapshot = self.layout orelse return;

        var live: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer live.deinit(self.alloc);
        for (snapshot.windows) |window| {
            live.put(self.alloc, window.id, {}) catch |err| {
                log.warn("failed to index live tmux window err={}", .{err});
                return;
            };
        }

        // Drop windows that no longer exist.
        var gi: usize = 0;
        while (gi < self.affinities.items.len) {
            const group = &self.affinities.items[gi];
            var ii: usize = 0;
            while (ii < group.items.len) {
                if (live.contains(group.items[ii])) {
                    ii += 1;
                    continue;
                }
                _ = group.orderedRemove(ii);
            }
            if (group.items.len == 0) {
                var removed = self.affinities.orderedRemove(gi);
                removed.deinit(self.alloc);
                continue;
            }
            gi += 1;
        }

        // Windows we have never classified.
        var unknown: std.ArrayList(usize) = .empty;
        defer unknown.deinit(self.alloc);
        for (snapshot.windows) |window| {
            if (self.affinityGroupIndex(window.id) != null) continue;
            unknown.append(self.alloc, window.id) catch |err| {
                log.warn("failed to collect new tmux window err={}", .{err});
                return;
            };
        }

        if (unknown.items.len > 0) {
            if (self.pending_affinity) |aff| {
                const target = self.affinityGroupIndex(aff) orelse self.affinities.items.len;
                if (target == self.affinities.items.len) {
                    var group: std.ArrayList(usize) = .empty;
                    group.append(self.alloc, aff) catch |err| {
                        log.warn("failed to create affinity group err={}", .{err});
                        self.pending_affinity = null;
                        return;
                    };
                    self.affinities.append(self.alloc, group) catch |err| {
                        log.warn("failed to store affinity group err={}", .{err});
                        group.deinit(self.alloc);
                        self.pending_affinity = null;
                        return;
                    };
                }
                const group = &self.affinities.items[self.affinityGroupIndex(aff).?];
                for (unknown.items) |id| {
                    if (id == aff) continue;
                    group.append(self.alloc, id) catch |err| {
                        log.warn("failed to extend affinity group err={}", .{err});
                        break;
                    };
                }
                self.pending_affinity = null;
            } else if (self.affinities.items.len == 0) {
                // Initial attach with no saved grouping: every tmux window
                // becomes a tab of one native window.
                var group: std.ArrayList(usize) = .empty;
                for (unknown.items) |id| {
                    group.append(self.alloc, id) catch |err| {
                        log.warn("failed to seed affinity group err={}", .{err});
                        group.deinit(self.alloc);
                        return;
                    };
                }
                self.affinities.append(self.alloc, group) catch |err| {
                    log.warn("failed to store affinity group err={}", .{err});
                    group.deinit(self.alloc);
                    return;
                };
            } else if (self.pending_new_group) {
                // Ghostty's own new_window: a native window of its own.
                self.pending_new_group = false;
                for (unknown.items) |id| {
                    var group: std.ArrayList(usize) = .empty;
                    group.append(self.alloc, id) catch |err| {
                        log.warn("failed to create affinity group err={}", .{err});
                        continue;
                    };
                    self.affinities.append(self.alloc, group) catch |err| {
                        log.warn("failed to store affinity group err={}", .{err});
                        group.deinit(self.alloc);
                    };
                }
            } else {
                // Any other new window, such as `new-window` from another
                // client or a pane broken out of its window, becomes a tab
                // next to the current window. A window can't be placed by
                // where it was created from, and a tab is what a new tmux
                // window looks like in every other client.
                const target = target: {
                    const current = self.active_window orelse break :target 0;
                    break :target self.affinityGroupIndex(current) orelse 0;
                };
                const group = &self.affinities.items[target];
                for (unknown.items) |id| {
                    group.append(self.alloc, id) catch |err| {
                        log.warn("failed to extend affinity group err={}", .{err});
                        break;
                    };
                }
            }
        }

        self.saveAffinities();
    }

    fn affinityGroupIndex(self: *const Session, window_id: usize) ?usize {
        for (self.affinities.items, 0..) |group, i| {
            for (group.items) |id| {
                if (id == window_id) return i;
            }
        }
        return null;
    }

    /// A follower already open in the same affinity group as `window_id`,
    /// used so `new_tab` adds a tab to that native window instead of
    /// opening another one (and never to the gateway's).
    fn affinitySiblingSurface(self: *const Session, window_id: usize) ?*Surface {
        const group_i = self.affinityGroupIndex(window_id) orelse return null;
        const group = self.affinities.items[group_i];
        for (group.items) |sibling_wid| {
            if (sibling_wid == window_id) continue;
            var it = self.pane_window.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.* != sibling_wid) continue;
                if (self.pane_to_surface.get(kv.key_ptr.*)) |surface| {
                    return surface;
                }
            }
        }
        return null;
    }

    fn saveAffinities(self: *Session) void {
        var stack_buf: [256]u8 = undefined;
        var stack: std.heap.BufferFirstAllocator = .init(&stack_buf, self.alloc);
        const alloc = stack.allocator();
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        const writer = &buf.writer;

        for (self.affinities.items, 0..) |group, gi| {
            if (gi > 0) writer.writeByte(' ') catch return;
            // Sort ids within a group for stable dumps.
            var sorted: std.ArrayList(usize) = .empty;
            defer sorted.deinit(alloc);
            sorted.appendSlice(alloc, group.items) catch return;
            std.mem.sort(usize, sorted.items, {}, std.sort.asc(usize));
            for (sorted.items, 0..) |id, ii| {
                if (ii > 0) writer.writeByte(',') catch return;
                writer.print("{d}", .{id}) catch return;
            }
        }

        const payload = buf.writer.buffered();
        if (self.last_affinities) |prev| {
            if (std.mem.eql(u8, prev, payload)) return;
        }

        const owned = self.alloc.dupe(u8, payload) catch return;
        if (self.last_affinities) |prev| self.alloc.free(prev);
        self.last_affinities = owned;

        // Persist on the attached session.
        // This goes through the viewer's queue like every other command:
        // tmux answers it with a block that would otherwise be taken as
        // the reply to whatever the viewer has in flight.
        var cmd_buf: [512]u8 = undefined;
        const command = std.fmt.bufPrint(
            &cmd_buf,
            "set @affinities \"{s}\"\n",
            .{owned},
        ) catch return;
        self.sendCommand(command);
    }

    fn indexPanes(self: *Session, window_id: usize, node: Layout) void {
        switch (node.content) {
            .pane => |id| self.pane_window.put(
                self.alloc,
                id,
                window_id,
            ) catch |err| {
                log.warn("failed to index tmux pane err={}", .{err});
            },

            .horizontal, .vertical => |children| for (children) |child| {
                self.indexPanes(window_id, child);
            },
        }
    }

    //---------------------------------------------------------------
    // Native layout
    //
    // With `native_layout` every tmux window is mirrored as one native tab
    // by sending the apprt the whole window (`apprt.Action.tmux_window`)
    // whenever something about it changes. The apprt reuses the surfaces
    // we name and creates the missing ones; those claim their pane when
    // their core surface initializes (`canClaim`).

    /// Bring every native tab in line with the last layout.
    fn mirror(self: *Session) void {
        const snapshot = self.layout orelse return;

        // tmux's current window, unless we asked for another one that it
        // hasn't switched to yet. tmux can change it without a word, for
        // example when `swap-window` swaps the current window away, so a
        // tab that is no longer the current one's is replaced as the
        // selected tab.
        const time = now();
        var reselect: ?usize = null;
        for (snapshot.windows) |window| {
            self.selection.listedPane(window.id, window.active_pane, time);
            if (!window.active) continue;
            if (self.selection.listedWindow(window.id, time) and
                self.mirrored.contains(window.id)) reselect = window.id;
        }
        self.selection.forget(self);
        self.active_window = self.selection.current();

        // Likewise a pane we focused but tmux hasn't reported yet stays
        // focused rather than going back to the one the layout names.
        if (self.selection.pending_pane) |pane| pending: {
            const window_id = self.pane_window.get(pane) orelse break :pending;
            const window = snapshot.findWindow(window_id) orelse break :pending;
            window.active_pane = pane;
        }

        // Surfaces whose pane is gone or now in another window can't stay
        // where they are. The tab that held them drops them; a moved pane
        // gets a new surface in its new tab.
        self.releaseMisplaced();
        self.pushGrids();

        // Every spec is built before any is sent: sending runs apprt code
        // that may call back into us (focus changes, surfaces closing).
        var arena: std.heap.ArenaAllocator = .init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();
        var specs: std.ArrayList(TmuxWindow.Spec) = .empty;

        // Tabs of windows that are gone close first, so that a native
        // window they leave empty isn't picked to hold a new tab.
        var it = self.mirrored.iterator();
        while (it.next()) |entry| {
            if (snapshot.findWindow(entry.key_ptr.*) != null) continue;
            specs.append(alloc, self.closedSpec(entry.key_ptr.*)) catch |err| {
                log.warn("failed to close tmux tab err={}", .{err});
            };
        }
        for (specs.items) |spec| {
            _ = self.mirrored.remove(spec.window);
            _ = self.window_sizes.remove(spec.window);
        }

        for (snapshot.windows) |*window| {
            const spec = self.buildSpec(
                alloc,
                window,
                reselect == window.id or
                    (!self.mirrored.contains(window.id) and
                        self.selection.current() == window.id),
            ) catch |err| {
                log.warn("failed to build tmux tab err={}", .{err});
                continue;
            };
            specs.append(alloc, spec) catch |err| {
                log.warn("failed to queue tmux tab err={}", .{err});
            };
        }

        // A new window starts at the size of its native window rather than
        // waiting for its tab to be shown.
        for (snapshot.windows) |window| {
            if (self.window_sizes.contains(window.id)) continue;
            const group = self.affinityGroupIndex(window.id) orelse continue;
            for (self.affinities.items[group].items) |id| {
                const size = self.window_sizes.get(id) orelse continue;
                self.sizeWindow(window.id, size);
                break;
            }
        }

        for (specs.items) |*spec| self.perform(spec);
    }

    /// Give tmux window `window_id` the size of its native tab, unless it
    /// already has it.
    fn sizeWindow(self: *Session, window_id: usize, size: renderer.GridSize) void {
        if (self.window_sizes.get(window_id)) |last| {
            if (last.columns == size.columns and last.rows == size.rows) return;
        }
        self.window_sizes.put(self.alloc, window_id, size) catch |err| {
            log.warn("failed to track tmux window size err={}", .{err});
            return;
        };
        self.sendCommandFmt(
            "refresh-client -C @{d}:{d}x{d}\n",
            .{ window_id, size.columns, size.rows },
        );
    }

    /// Send one window's tab again, for example after a rename or to
    /// select it. Its layout hasn't changed, so its surfaces are where
    /// they were.
    fn sendWindow(self: *Session, window_id: usize, select: bool) void {
        if (!self.mirrored.contains(window_id)) return;
        const snapshot = self.layout orelse return;
        const window = snapshot.findWindow(window_id) orelse return;

        var arena: std.heap.ArenaAllocator = .init(self.alloc);
        defer arena.deinit();
        var spec = self.buildSpec(arena.allocator(), window, select) catch |err| {
            log.warn("failed to build tmux tab err={}", .{err});
            return;
        };
        self.perform(&spec);
    }

    /// Describe the tab of `window` and record what it is about to show.
    fn buildSpec(
        self: *Session,
        alloc: Allocator,
        window: *const Snapshot.Window,
        select: bool,
    ) !TmuxWindow.Spec {
        const snapshot = self.layout.?;

        // While zoomed, tmux shows one pane at the size of the window.
        const zoomed: ?usize = zoomed: {
            if (!window.zoomed) break :zoomed null;
            const visible = window.visible_layout orelse break :zoomed window.active_pane;
            break :zoomed switch (visible.content) {
                .pane => |pane| pane,
                .horizontal, .vertical => window.active_pane,
            };
        };

        const tree: tmux_mirror.Tree = try .init(
            alloc,
            window.layout,
            zoomed,
            window.active_pane,
        );
        for (tree.nodes) |*node| switch (node.*) {
            .leaf => |*leaf| {
                leaf.surface = self.pane_to_surface.get(leaf.pane);
                try self.placed.put(self.alloc, leaf.pane, window.id);
            },
            .split => {},
        };

        const order = try alloc.alloc(usize, snapshot.windows.len);
        for (snapshot.windows, order) |w, *id| id.* = w.id;
        const group: []const usize = if (self.affinityGroupIndex(window.id)) |i|
            self.affinities.items[i].items
        else
            &.{window.id};
        const place = tmux_mirror.placement(order, group, window.id, self);

        self.spec_serial += 1;
        try self.mirrored.put(self.alloc, window.id, self.spec_serial);

        return .{
            .session = self.attach,
            .window = window.id,
            .serial = self.spec_serial,
            .nodes = tree.nodes,
            .zoomed = tree.zoomed,
            .focused = tree.focused,
            .title = try alloc.dupeSentinel(u8, window.name, 0),
            .beside = place.beside,
            .after = place.after,
            .select = select,
            .parent = self.leader,
        };
    }

    /// A spec that closes the tab of a window that is gone.
    fn closedSpec(self: *Session, window_id: usize) TmuxWindow.Spec {
        self.spec_serial += 1;
        return .{
            .session = self.attach,
            .window = window_id,
            .serial = self.spec_serial,
            .nodes = &.{},
            .zoomed = null,
            .focused = null,
            .title = "",
            .beside = null,
            .after = null,
            .select = false,
            .parent = null,
        };
    }

    fn perform(self: *Session, spec: *const TmuxWindow.Spec) void {
        log.debug(
            "tab window=@{d} serial={d} nodes={d} select={} zoomed={?d} title={s}",
            .{ spec.window, spec.serial, spec.nodes.len, spec.select, spec.zoomed, spec.title },
        );
        const handled = self.leader.rt_app.performAction(
            .{ .surface = self.leader },
            .tmux_window,
            .{ .spec = spec },
        ) catch |err| {
            log.warn("failed to mirror tmux window err={}", .{err});
            return;
        };
        if (!handled) log.warn("apprt did not mirror tmux window @{d}", .{spec.window});
    }

    /// Release the followers whose pane is gone, or is in another window
    /// than the tab that holds the follower.
    fn releaseMisplaced(self: *Session) void {
        var misplaced: std.ArrayList(*Surface) = .empty;
        defer misplaced.deinit(self.alloc);

        var it = self.pane_to_surface.iterator();
        while (it.next()) |entry| {
            const pane = entry.key_ptr.*;
            if (!tmux_mirror.isMisplaced(self.pane_window, self.placed, pane)) continue;
            misplaced.append(self.alloc, entry.value_ptr.*) catch |err| {
                log.warn("failed to collect moved tmux pane err={}", .{err});
            };
        }

        for (misplaced.items) |surface| {
            log.debug("release pane=%{?d}", .{self.paneForSurface(surface)});
            self.releaseSurface(surface);
        }
    }

    /// Give every follower the grid tmux gives its pane, when it changed.
    fn pushGrids(self: *Session) void {
        const snapshot = self.layout orelse return;
        var grids: std.ArrayList(tmux_mirror.PaneGrid) = .empty;
        defer grids.deinit(self.alloc);
        for (snapshot.windows) |window| {
            tmux_mirror.appendPaneGrids(
                self.alloc,
                &grids,
                window.layout,
                if (window.zoomed) window.visible_layout else null,
            ) catch |err| {
                log.warn("failed to size tmux panes err={}", .{err});
                return;
            };
        }

        for (grids.items) |v| {
            const surface = self.pane_to_surface.get(v.pane) orelse continue;
            const grid = gridSize(v.columns, v.rows);
            if (self.grids.get(v.pane)) |last| {
                if (last.columns == grid.columns and last.rows == grid.rows) continue;
            }
            self.grids.put(self.alloc, v.pane, grid) catch |err| {
                log.warn("failed to track tmux pane grid err={}", .{err});
                continue;
            };

            log.debug("grid pane=%{d} {d}x{d}", .{ v.pane, grid.columns, grid.rows });
            surface.tmux_grid = grid;
            surface.io.queueMessage(.{ .tmux_grid = grid }, .unlocked);
        }
    }

    /// For `tmux_mirror`: whether a tmux window has a tab.
    pub fn hasTab(self: *const Session, window_id: usize) bool {
        return self.mirrored.contains(window_id);
    }

    /// For `tmux_mirror.Selection.forget`.
    pub fn hasWindow(self: *const Session, window_id: usize) bool {
        const snapshot = self.layout orelse return false;
        return snapshot.findWindow(window_id) != null;
    }

    /// For `tmux_mirror.Selection.forget`.
    pub fn hasPane(self: *const Session, pane_id: usize) bool {
        return self.pane_window.contains(pane_id);
    }

    /// Something happened to a mirrored tab on the native side.
    pub const NativeEvent = union(enum) {
        /// The user selected the tab of a tmux window.
        tab_selected: Tab,

        /// The area that shows the tab's panes has this size, in device
        /// pixels. The tab is the one shown in its native window.
        view_size: ViewSize,

        /// The user dragged a divider of the tab to a new ratio.
        split_ratio: SplitRatio,

        /// The user reordered the tabs of a native window.
        reorder: Reorder,

        /// A tab moved to another native window, or to a new one.
        regroup: Regroup,

        /// The user closed the tab, with its close button or its menu.
        close_tab: Tab,

        /// A split was dragged onto the event's surface, to be placed
        /// beside it.
        move_pane: MovePane,

        pub const Tab = struct {
            /// `TmuxWindow.Spec.session` of the tab.
            session: u64,
            window: usize,
        };

        pub const ViewSize = struct {
            tab: Tab,
            width: u32,
            height: u32,
        };

        pub const SplitRatio = struct {
            tab: Tab,

            /// `TmuxWindow.Spec.serial` of the tree that was dragged.
            serial: u64,

            /// The split's node handle in that tree.
            handle: u16,

            /// The new share of the split's left (or top) half.
            ratio: f64,
        };

        pub const Reorder = struct {
            /// `TmuxWindow.Spec.session` of the tabs.
            session: u64,

            /// The tmux windows of the native window's tabs, in their
            /// new order.
            windows: []const usize,
        };

        pub const Regroup = struct {
            tab: Tab,

            /// A tmux window that already had a tab in the native window
            /// the tab moved to, or null if it has none.
            beside: ?usize,
        };

        pub const MovePane = struct {
            /// The surface that was dragged.
            source: *const Surface,

            /// Where it goes, relative to the event's surface.
            direction: apprt.action.SplitDirection,
        };
    };

    /// Handle a native event. `surface` is a surface of the tab, or any
    /// surface with the same font and padding; for `move_pane` it is the
    /// surface the split was dropped on. Returns false if the event isn't
    /// about this session, so the apprt handles it natively.
    pub fn nativeEvent(self: *Session, surface: *const Surface, event: NativeEvent) bool {
        switch (event) {
            .view_size => |v| {
                if (v.tab.session != self.attach) return false;
                if (!self.mirrored.contains(v.tab.window)) return false;

                // The cells that fit, as for a surface of that size. tmux
                // adds the dividers between panes, which natively are thin
                // borders, so a split tab ends up with a little room to
                // spare rather than clipping.
                const size = surface.size;
                const pad_w = size.padding.left + size.padding.right;
                const pad_h = size.padding.top + size.padding.bottom;
                if (v.width <= pad_w or v.height <= pad_h) return true;
                const grid = gridSize(
                    (v.width - pad_w) / size.cell.width,
                    (v.height - pad_h) / size.cell.height,
                );

                // Only the shown tab of a native window gets a size, but
                // its other tabs are the same size.
                const group: []const usize = if (self.affinityGroupIndex(v.tab.window)) |i|
                    self.affinities.items[i].items
                else
                    &.{v.tab.window};
                for (group) |id| self.sizeWindow(id, grid);
                return true;
            },

            .tab_selected => |tab| {
                if (tab.session != self.attach) return false;
                if (!self.mirrored.contains(tab.window)) return false;
                if (!self.selection.nativeWindow(tab.window, now())) return true;
                self.active_window = self.selection.current();
                if (self.layout) |snapshot| snapshot.setActiveWindow(tab.window);
                self.sendCommandFmt("select-window -t @{d}\n", .{tab.window});
                return true;
            },

            .split_ratio => |v| {
                if (v.tab.session != self.attach) return false;
                const serial = self.mirrored.get(v.tab.window) orelse return false;

                // The tab was set from a newer spec since, whose splits
                // may not be the ones the handle names.
                if (serial != v.serial) return true;
                self.resizeSplit(v.tab.window, v.handle, v.ratio);
                return true;
            },

            .reorder => |v| {
                if (v.session != self.attach) return false;
                self.reorderWindows(v.windows);
                return true;
            },

            .regroup => |v| {
                if (v.tab.session != self.attach) return false;
                if (!self.mirrored.contains(v.tab.window)) return false;
                self.joinGroup(v.tab.window, v.beside);
                return true;
            },

            // A tab only closes once tmux reports its window gone, so a
            // window that survives the kill (tmux refused, or the session
            // is gone and so is the tab) never leaves a tab without one.
            .close_tab => |tab| {
                if (tab.session != self.attach) return false;
                if (!self.mirrored.contains(tab.window)) return false;
                self.sendCommandFmt("kill-window -t @{d}\n", .{tab.window});
                return true;
            },

            .move_pane => |v| {
                const target = self.paneForSurface(surface) orelse return false;
                const source = self.paneForSurface(v.source) orelse return false;
                if (source == target) return true;

                // The same flags as a split in that direction: `-b` puts
                // the pane before the target.
                const flag: []const u8 = switch (v.direction) {
                    .right => "-h",
                    .left => "-hb",
                    .down => "-v",
                    .up => "-vb",
                };
                self.sendCommandFmt(
                    "move-pane {s} -s %{d} -t %{d}\n",
                    .{ flag, source, target },
                );
                return true;
            },
        }
    }

    /// Move a divider of the tab of `window_id` to where the user dragged
    /// it, by resizing the tmux pane it belongs to. tmux answers with a
    /// layout change, and the tab follows that, cell for cell.
    fn resizeSplit(
        self: *Session,
        window_id: usize,
        handle: u16,
        ratio: f64,
    ) void {
        const snapshot = self.layout orelse return;
        const window = snapshot.findWindow(window_id) orelse return;

        // Some dividers can't be moved with one resize-pane (see
        // `tmux_mirror.resizeForRatio`). Those go back where tmux has
        // them.
        const resize = tmux_mirror.resizeForRatio(window.layout, handle, ratio) orelse {
            log.info("no tmux resize for split={d} of @{d}, restoring it", .{ handle, window_id });
            self.sendWindow(window_id, false);
            return;
        };

        // A drag that ends within the cell it started in resizes nothing,
        // and tmux reports no layout change that would put the divider
        // back on a cell boundary.
        if (resize.unchanged(window.layout)) {
            self.sendWindow(window_id, false);
            return;
        }

        self.sendCommandFmt("resize-pane -t %{d} -{c} {d}\n", .{
            resize.pane,
            @as(u8, switch (resize.layout) {
                .horizontal => 'x',
                .vertical => 'y',
            }),
            resize.cells,
        });
    }

    /// Reorder tmux windows to match a new native tab order. Windows that
    /// aren't in `windows` keep their indexes.
    fn reorderWindows(self: *Session, windows: []const usize) void {
        const snapshot = self.layout orelse return;

        var arena: std.heap.ArenaAllocator = .init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        const order = alloc.alloc(usize, snapshot.windows.len) catch |err| {
            log.warn("failed to reorder tmux windows err={}", .{err});
            return;
        };
        for (snapshot.windows, order) |w, *id| id.* = w.id;
        const swaps = tmux_mirror.planSwaps(alloc, order, windows) catch |err| {
            log.warn("failed to reorder tmux windows err={}", .{err});
            return;
        };
        if (swaps.len == 0) return;

        // `swap-window` leaves the session's current index alone, so when
        // the current window is swapped away the window swapped in becomes
        // the current one, and tmux says nothing about it. Selecting the
        // window again keeps the selected tab current.
        const current = self.selection.current();
        var reselect = false;
        for (swaps) |swap| {
            self.sendCommandFmt(
                "swap-window -s @{d} -t @{d}\n",
                .{ swap.a, swap.b },
            );
            if (current == swap.a or current == swap.b) reselect = true;

            // Until tmux lists the windows again, our idea of the order is
            // what further reorders are planned against.
            const a = std.mem.indexOfScalar(usize, order, swap.a).?;
            const b = std.mem.indexOfScalar(usize, order, swap.b).?;
            std.mem.swap(usize, &order[a], &order[b]);
            std.mem.swap(Snapshot.Window, &snapshot.windows[a], &snapshot.windows[b]);
            std.mem.swap(usize, &snapshot.windows[a].index, &snapshot.windows[b].index);
        }
        if (reselect) self.sendCommandFmt("select-window -t @{d}\n", .{current.?});
        self.refreshWindows();
    }

    /// Put `window_id` into the group of `beside`, or into a group of its
    /// own if that is null: its tab moved to another native window, and
    /// the next layout must keep it there.
    fn joinGroup(self: *Session, window_id: usize, beside: ?usize) void {
        const other = beside orelse return self.regroupWindow(window_id);
        const target = self.affinityGroupIndex(other) orelse return self.regroupWindow(window_id);
        if (self.affinityGroupIndex(window_id) == target) return;

        // Removing the window can drop the group it leaves empty, which
        // shifts the indexes, so the target group is looked up again.
        self.removeWindowFromAffinities(window_id);
        const group = &self.affinities.items[self.affinityGroupIndex(other).?];
        group.append(self.alloc, window_id) catch |err| {
            log.warn("failed to extend affinity group err={}", .{err});
        };
        self.saveAffinities();
    }

    /// Close every mirrored tab. Followers are forgotten first so that
    /// closing them doesn't kill their panes.
    fn closeTabs(self: *Session) void {
        self.pane_to_surface.clearRetainingCapacity();
        self.surface_to_pane.clearRetainingCapacity();

        var windows: std.ArrayList(usize) = .empty;
        defer windows.deinit(self.alloc);
        var it = self.mirrored.keyIterator();
        while (it.next()) |id| windows.append(self.alloc, id.*) catch |err| {
            log.warn("failed to collect tmux tab err={}", .{err});
        };
        self.mirrored.clearRetainingCapacity();

        for (windows.items) |id| {
            const spec = self.closedSpec(id);
            self.perform(&spec);
        }
    }

    /// Close the followers whose pane no longer exists in tmux. We
    /// unregister them first so that closing doesn't send `kill-pane`
    /// back for a pane that is already gone.
    fn closeStalePanes(self: *Session) void {
        var stale: std.ArrayList(*Surface) = .empty;
        defer stale.deinit(self.alloc);

        {
            var it = self.pane_to_surface.iterator();
            while (it.next()) |kv| {
                if (self.pane_window.contains(kv.key_ptr.*)) continue;
                stale.append(self.alloc, kv.value_ptr.*) catch |err| {
                    log.warn("failed to collect stale tmux pane err={}", .{err});
                };
            }
        }

        for (stale.items) |surface| {
            self.unregisterSurface(surface);
            surface.close();
        }
    }

    /// Create native surfaces until every pane in the layout has one.
    ///
    /// Surfaces are created one at a time because each one needs a parent
    /// surface to split from. When the apprt creates surfaces
    /// synchronously the loop below does all of them; when it doesn't,
    /// `pending` is still set on return and the follower calls us back
    /// once it registers itself.
    pub fn advance(self: *Session) void {
        if (comptime native_layout) return;
        if (self.advancing) return;

        // A surface we asked for hasn't come back yet. Creating another
        // one now would leave two surfaces racing for the same pane, so
        // wait for the follower to register and call us again.
        if (self.pending != null) return;

        self.advancing = true;
        defer self.advancing = false;

        var i: usize = 0;
        while (i < max_advance) : (i += 1) {
            const next = self.nextMissingPane() orelse break;
            self.pending = next.pane;

            if (next.source) |source| {
                _ = source.rt_app.performAction(
                    .{ .surface = source },
                    .new_split,
                    next.direction,
                ) catch |err| {
                    log.warn("failed to create tmux split err={}", .{err});
                    self.pending = null;
                    break;
                };
            } else {
                // First pane of a tmux window: never a tab beside the
                // gateway, which keeps the control plate alone. Panes open
                // in their own native window, or as a tab beside an
                // affinity sibling after `new_tab`.
                const window_id = self.pane_window.get(next.pane);
                const sibling = if (window_id) |wid|
                    self.affinitySiblingSurface(wid)
                else
                    null;
                if (sibling) |surface| {
                    _ = surface.rt_app.performAction(
                        .{ .surface = surface },
                        .new_tab,
                        {},
                    ) catch |err| {
                        log.warn("failed to create tmux tab err={}", .{err});
                        self.pending = null;
                        break;
                    };
                } else {
                    var surfaces = self.pane_to_surface.valueIterator();
                    const source = if (surfaces.next()) |surface|
                        surface.*
                    else
                        self.leader;
                    _ = source.rt_app.performAction(
                        .{ .surface = source },
                        .new_window,
                        {},
                    ) catch |err| {
                        log.warn("failed to create tmux window err={}", .{err});
                        self.pending = null;
                        break;
                    };
                }
            }

            // Surface creation was asynchronous. The follower will call
            // us again once it has registered itself.
            if (self.pending != null) break;

            // The pane was claimed but no surface registered, so there
            // is nothing to split from next time around.
            if (!self.pane_to_surface.contains(next.pane)) break;
        }
    }

    const MissingPane = struct {
        pane: usize,

        /// The surface to split from, or null to open a new window/tab.
        source: ?*Surface,

        direction: apprt.action.SplitDirection,
    };

    fn nextMissingPane(self: *Session) ?MissingPane {
        const snapshot = self.layout orelse return null;

        var panes: std.ArrayList(PaneRef) = .empty;
        defer panes.deinit(self.alloc);

        // Restore one native root for every affinity group before adding
        // sibling tabs. AppKit may not accept a new tab while the first
        // reconstructed window is still being presented; rooting groups
        // first also makes their OS-window boundaries explicit.
        for (self.affinities.items) |group| {
            var group_has_surface = false;
            for (group.items) |window_id| {
                if (self.windowHasSurface(window_id)) {
                    group_has_surface = true;
                    break;
                }
            }
            if (group_has_surface) continue;

            for (group.items) |window_id| {
                const window = for (snapshot.windows) |candidate| {
                    if (candidate.id == window_id) break candidate;
                } else continue;
                panes.clearRetainingCapacity();
                self.flatten(&panes, window.layout, .right);
                for (panes.items) |pane| {
                    if (self.pane_to_surface.contains(pane.id)) continue;
                    return .{
                        .pane = pane.id,
                        .source = null,
                        .direction = pane.direction,
                    };
                }
            }
        }

        for (snapshot.windows) |window| {
            panes.clearRetainingCapacity();
            self.flatten(&panes, window.layout, .right);

            // Any surface in this window means the tab itself already
            // exists, so a missing pane is a split rather than a new
            // tab. This matters when tmux adds a pane ahead of the
            // ones we already have.
            const anchor: ?*Surface = anchor: for (panes.items) |pane| {
                if (self.pane_to_surface.get(pane.id)) |surface| {
                    break :anchor surface;
                }
            } else null;

            var prev: ?*Surface = null;
            for (panes.items) |pane| {
                if (self.pane_to_surface.get(pane.id)) |surface| {
                    prev = surface;
                    continue;
                }

                return .{
                    .pane = pane.id,
                    .source = if (anchor == null) null else prev orelse anchor,
                    .direction = pane.direction,
                };
            }
        }

        return null;
    }

    const PaneRef = struct {
        id: usize,

        /// The direction of the split that separates this pane from the
        /// one before it in layout order.
        direction: apprt.action.SplitDirection,
    };

    /// Flatten a layout tree into the order we create panes in. The
    /// direction recorded for a pane is the one of its nearest enclosing
    /// split, which reproduces simple layouts exactly and stays close for
    /// deeply nested ones.
    fn flatten(
        self: *Session,
        list: *std.ArrayList(PaneRef),
        node: Layout,
        direction: apprt.action.SplitDirection,
    ) void {
        switch (node.content) {
            .pane => |id| list.append(self.alloc, .{
                .id = id,
                .direction = direction,
            }) catch |err| {
                log.warn("failed to flatten tmux layout err={}", .{err});
            },

            // tmux spells a left/right split `{}` and a top/bottom
            // split `[]`.
            inline .horizontal, .vertical => |children, tag| {
                const child_direction: apprt.action.SplitDirection =
                    if (tag == .horizontal) .right else .down;
                for (children, 0..) |child, i| self.flatten(
                    list,
                    child,
                    if (i == 0) direction else child_direction,
                );
            },
        }
    }

    /// Close every follower surface, leaving the gateway alone.
    pub fn closeFollowers(self: *Session) void {
        if (comptime native_layout) {
            self.closeTabs();
            self.pane_window.clearRetainingCapacity();
            self.captured.clearRetainingCapacity();
            self.placed.clearRetainingCapacity();
            self.grids.clearRetainingCapacity();
            self.window_sizes.clearRetainingCapacity();
            if (self.layout) |v| {
                v.destroy();
                self.layout = null;
            }
            return;
        }

        var surfaces: std.ArrayList(*Surface) = .empty;
        defer surfaces.deinit(self.alloc);

        var it = self.pane_to_surface.valueIterator();
        while (it.next()) |ptr| {
            if (ptr.* == self.leader) continue;
            surfaces.append(self.alloc, ptr.*) catch |err| {
                log.warn("failed to collect tmux follower err={}", .{err});
            };
        }

        self.pane_to_surface.clearRetainingCapacity();
        self.surface_to_pane.clearRetainingCapacity();
        self.pane_window.clearRetainingCapacity();
        self.captured.clearRetainingCapacity();
        self.pending = null;
        if (self.layout) |v| {
            v.destroy();
            self.layout = null;
        }

        for (surfaces.items) |surface| surface.close();
    }

    //---------------------------------------------------------------
    // Action translation
    //
    // What `tmux_action.zig` needs to know about where an action came
    // from, and the bookkeeping that some of its results call for.

    /// The tmux window a pane is in, as of the last layout.
    pub fn windowForPane(self: *const Session, pane_id: usize) ?usize {
        return self.pane_window.get(pane_id);
    }

    /// The tmux windows that are tabs of the same native window as
    /// `window_id`, in tab order, including `window_id` itself. The
    /// caller owns the result.
    ///
    /// The order is the order tmux lists windows in, which is by index.
    /// That is also what a tab move changes. Windows that aren't tabs yet
    /// are left out: with native tabs those that haven't been mirrored,
    /// otherwise those without a surface.
    pub fn tabOrder(
        self: *const Session,
        alloc: Allocator,
        window_id: usize,
    ) Allocator.Error![]usize {
        var tabs: std.ArrayList(usize) = .empty;
        errdefer tabs.deinit(alloc);

        if (self.affinityGroupIndex(window_id)) |group_index| {
            for (self.affinities.items[group_index].items) |id| {
                if (id != window_id and !self.isTab(id)) continue;
                try tabs.append(alloc, id);
            }
        } else {
            try tabs.append(alloc, window_id);
        }

        std.mem.sort(usize, tabs.items, self, windowListedBefore);
        return tabs.toOwnedSlice(alloc);
    }

    /// Whether a tmux window has a tab. A mirrored tab exists before its
    /// surfaces have initialized.
    fn isTab(self: *const Session, window_id: usize) bool {
        if (comptime native_layout) return self.mirrored.contains(window_id);
        return self.windowHasSurface(window_id);
    }

    fn windowListedBefore(self: *const Session, a: usize, b: usize) bool {
        const rank_a = self.windowRank(a);
        const rank_b = self.windowRank(b);
        if (rank_a != rank_b) return rank_a < rank_b;
        return a < b;
    }

    /// Where tmux lists a window in the last layout, or past the end if
    /// it isn't there.
    fn windowRank(self: *const Session, window_id: usize) usize {
        const snapshot = self.layout orelse return std.math.maxInt(usize);
        for (snapshot.windows, 0..) |window, i| {
            if (window.id == window_id) return i;
        }
        return std.math.maxInt(usize);
    }

    /// Give a tmux window a native window of its own. A tab moved to a
    /// new native window has to be reflected in the groups, otherwise
    /// the next layout would put it back.
    pub fn regroupWindow(self: *Session, window_id: usize) void {
        var group: std.ArrayList(usize) = .empty;
        group.append(self.alloc, window_id) catch |err| {
            log.warn("failed to create affinity group err={}", .{err});
            return;
        };

        self.removeWindowFromAffinities(window_id);
        self.affinities.append(self.alloc, group) catch |err| {
            log.warn("failed to store affinity group err={}", .{err});
            group.deinit(self.alloc);
            return;
        };
        self.saveAffinities();
    }
};

/// Milliseconds on a monotonic clock, for `tmux_mirror.Selection`.
fn now() i64 {
    return std.Io.Timestamp.now(global.io(), .awake).toMilliseconds();
}

/// The terminal grid for a pane of `columns` x `rows` cells.
fn gridSize(columns: usize, rows: usize) renderer.GridSize {
    const max = std.math.maxInt(renderer.GridSize.Unit);
    return .{
        .columns = @intCast(std.math.clamp(columns, 1, max)),
        .rows = @intCast(std.math.clamp(rows, 1, max)),
    };
}

/// The grid of `pane_id` in a window laid out as `layout`, or null if the
/// pane isn't in it. See `tmux_mirror.appendPaneGrids` for `visible`.
fn findPaneGrid(layout: Layout, visible: ?Layout, pane_id: usize) ?renderer.GridSize {
    if (visible) |v| switch (v.content) {
        .pane => |id| if (id == pane_id) return gridSize(v.width, v.height),
        .horizontal, .vertical => {},
    };

    switch (layout.content) {
        .pane => |id| return if (id == pane_id)
            gridSize(layout.width, layout.height)
        else
            null,
        .horizontal, .vertical => |children| for (children) |child| {
            if (findPaneGrid(child, null, pane_id)) |grid| return grid;
        },
    }
    return null;
}
