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

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("apprt.zig");
const termio = @import("termio.zig");
const terminal = @import("terminal/main.zig");
const Surface = @import("Surface.zig");
const Layout = terminal.tmux.Layout;
const Snapshot = terminal.tmux.Snapshot;

const log = std.log.scoped(.tmux_session);

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

    /// Native-window grouping of tmux windows, matching iTerm2's
    /// ``@affinities`` session option. Each inner list is the set of
    /// tmux window ids that share one OS window as tabs.
    affinities: std.ArrayList(std.ArrayList(usize)) = .empty,

    /// When the user creates a tab (Cmd+T), the next tmux window should
    /// join this window's affinity group — the same bookkeeping iTerm2
    /// does with ``newWindowWithAffinity:``.
    pending_affinity: ?usize = null,

    /// Tmux's active window id, from select-pane we send on focus and from
    /// ``%window-pane-changed`` notifications (including external
    /// ``select-window``). Cmd+T prefers this so affinity stays correct
    /// when GUI focus lags across OS windows.
    active_window: ?usize = null,

    /// Last ``set @affinities`` payload we sent, to avoid spamming tmux.
    last_affinities: ?[]u8 = null,

    pub fn init(alloc: Allocator, leader: *Surface) Session {
        return .{ .alloc = alloc, .leader = leader };
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

    pub fn unregisterSurface(self: *Session, surface: *Surface) void {
        if (self.surface_to_pane.fetchRemove(surface.id)) |kv| {
            const pane_id = kv.value;
            const window_id = self.pane_window.get(pane_id);
            _ = self.pane_to_surface.remove(pane_id);
            _ = self.captured.remove(pane_id);
            _ = self.pane_window.remove(pane_id);

            // Closing the last native surface for a tmux window should
            // drop it from @affinities immediately (do not wait for the
            // next list-windows), matching iTerm2's bookkeeping on tab close.
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
        const data = self.alloc.dupe(u8, command) catch |err| {
            log.warn("failed to allocate tmux command err={}", .{err});
            return;
        };

        self.leader.io.queueMessage(.{ .tmux_command = .{
            .alloc = self.alloc,
            .data = data,
        } }, .unlocked);
    }

    /// Write bytes straight to the gateway pty, bypassing the viewer's
    /// command queue. Use this when we're about to tear the viewer down
    /// (detach / force-quit): a queued `tmux_command` would be freed with
    /// the viewer and never reach tmux.
    pub fn sendRaw(self: *Session, command: []const u8) void {
        if (command.len == 0) return;
        const data = self.alloc.dupe(u8, command) catch |err| {
            log.warn("failed to allocate tmux raw write err={}", .{err});
            return;
        };

        self.leader.io.queueMessage(.{ .write_alloc = .{
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
        var stack = std.heap.stackFallback(256, self.alloc);
        const alloc = stack.get();
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
    /// null the session's active pane is targeted.
    ///
    /// Bytes go out as `send-keys -H` codepoints rather than `-l` literals
    /// because tmux's command parser treats `;`, `$`, `#` and quotes as
    /// syntax, so a literal semicolon never reaches the pane.
    pub fn sendKeys(self: *Session, pane_id: ?usize, data: []const u8) void {
        if (data.len == 0) return;

        var stack = std.heap.stackFallback(512, self.alloc);
        const alloc = stack.get();

        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        const writer = &buf.writer;

        writer.writeAll("send-keys") catch return;
        if (pane_id) |id| writer.print(" -t %{d}", .{id}) catch return;
        writer.writeAll(" -H") catch return;

        // Send codepoints, not bytes: `-H` values are Unicode codepoints
        // so tmux would re-encode every byte of a multi-byte sequence.
        var i: usize = 0;
        while (i < data.len) {
            var cp: u21 = data[i];
            var len: usize = 1;
            decode: {
                const seq_len = std.unicode.utf8ByteSequenceLength(
                    data[i],
                ) catch break :decode;
                if (i + seq_len > data.len) break :decode;
                cp = std.unicode.utf8Decode(
                    data[i..][0..seq_len],
                ) catch break :decode;
                len = seq_len;
            }

            writer.print(" 0x{x}", .{cp}) catch return;
            i += len;
        }

        writer.writeByte('\n') catch return;
        self.sendCommand(buf.writer.buffered());
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
        // Sizing a window by hand took it off tmux's automatic sizing,
        // and that would otherwise follow the session to its next
        // client.
        if (self.layout) |snapshot| {
            for (snapshot.windows) |window| {
                var stack = std.heap.stackFallback(128, self.alloc);
                const alloc = stack.get();
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
        }

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
        if (self.layout) |old| old.destroy();
        self.layout = snapshot;

        // Rebuild the pane -> window index.
        self.pane_window.clearRetainingCapacity();
        for (snapshot.windows) |window| {
            self.indexPanes(window.id, window.layout);
        }

        self.syncAffinities();
        self.closeStalePanes();
        self.advance();
    }

    /// Remember which tmux window a forthcoming ``new-window`` should share
    /// an OS window with (iTerm2 affinity for Cmd+T / New Tab).
    pub fn noteTabAffinity(self: *Session, surface: *Surface) void {
        // Prefer tmux's active window when known. GUI focus across multiple
        // Ghostty OS windows can lag (Accessibility raise / Cmd+`), while
        // ``select-window`` / ``select-pane`` still update tmux — Cmd+T
        // should follow that.
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

        // Gateway has no pane: affinity to the first live window, which is
        // what iTerm2 does when the control plate issues New Tab.
        if (self.layout) |snapshot| {
            if (snapshot.windows.len > 0) {
                self.pending_affinity = snapshot.windows[0].id;
            }
        }
    }

    pub fn setActiveWindow(self: *Session, window_id: usize) void {
        self.active_window = window_id;
    }

    /// Keep ``@affinities`` in sync with the live window list and persist it.
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
                // Initial attach: Ghostty (like iTerm2 Cmd+T) keeps every
                // tmux window as a tab of one native window.
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
            } else {
                // Anonymous ``new-window`` from outside: each alone, matching
                // iTerm2's default for windows without an affinity hint.
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

    /// A follower already open in the same affinity group as ``window_id``,
    /// used so Cmd+T can add a tab to that native window instead of opening
    /// another OS window (and never the gateway).
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
        var stack = std.heap.stackFallback(256, self.alloc);
        const alloc = stack.get();
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

        // Persist on the attached session, same option iTerm2 uses.
        // sendRaw so this is not stuck behind capture-pane traffic in
        // the viewer's command queue — e2e reads @affinities from a
        // parallel tmux client.
        var cmd_buf: [512]u8 = undefined;
        const command = std.fmt.bufPrint(
            &cmd_buf,
            "set @affinities \"{s}\"\n",
            .{owned},
        ) catch return;
        self.sendRaw(command);
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
                // First pane of a tmux window: never a tab on the gateway.
                // iTerm2 keeps the control plate alone; mux panes open in
                // their own native window, or as a tab beside an affinity
                // sibling when the user pressed Cmd+T.
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
                    _ = self.leader.rt_app.performAction(
                        .{ .surface = self.leader },
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
};
