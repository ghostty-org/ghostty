const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing = std.testing;
const assert = @import("../../quirks.zig").inlineAssert;
const size = @import("../size.zig");
const CircBuf = @import("../../datastruct/main.zig").CircBuf;
const CursorStyle = @import("../cursor.zig").Style;
const Screen = @import("../Screen.zig");
const Style = @import("../style.zig").Style;
const ansi = @import("../ansi.zig");
const ScreenSet = @import("../ScreenSet.zig");
const Terminal = @import("../Terminal.zig");
const Layout = @import("layout.zig").Layout;
const control = @import("control.zig");
const output = @import("output.zig");
const TerminalStream = @import("../stream_terminal.zig").Stream;

const log = std.log.scoped(.terminal_tmux_viewer);

// TODO: A list of TODOs as I think about them.
// - We need to make startup more robust so session and block can happen
//   out of order.
// - We need to ignore `output` for panes that aren't yet initialized
//   (until capture-panes are complete).

// NOTE: There is some fragility here that can possibly break if tmux
// changes their implementation. In particular, the order of notifications
// and assurances about what is sent when are based on reading the tmux
// source code as of Dec, 2025. These aren't documented as fixed.
//
// I've tried not to depend on anything that seems like it'd change
// in the future. For example, it seems reasonable that command output
// always comes before session attachment. But, I am noting this here
// in case something breaks in the future we can consider it. We should
// be able to easily unit test all variations seen in the real world.

/// The initial capacity of the command queue. We dynamically resize
/// as necessary so the initial value isn't that important, but if we
/// want to feel good about it we should make it large enough to support
/// our most realistic use cases without resizing.
const COMMAND_QUEUE_INITIAL = 8;

/// A viewer is a tmux control mode client that attempts to create
/// a remote view of a tmux session, including providing the ability to send
/// new input to the session.
///
/// This is the primary use case for tmux control mode, but technically
/// tmux control mode clients can do anything a normal tmux client can do,
/// so the `control.zig` and other files in this folder are more general
/// purpose.
///
/// This struct helps move through a state machine of connecting to a tmux
/// session, negotiating capabilities, listing window state, etc.
///
/// ## Viewer Lifecycle
///
/// The viewer progresses through several states from initial connection
/// to steady-state operation. Here is the full flow:
///
/// ```
///                              ┌─────────────────────────────────────────────┐
///                              │           TMUX CONTROL MODE START           │
///                              │         (DCS 1000p received by host)        │
///                              └─────────────────┬───────────────────────────┘
///                                                │
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │            startup_block                    │
///                              │                                             │
///                              │  Wait for initial %begin/%end block from    │
///                              │  tmux. This is the response to the initial  │
///                              │  command (e.g., "attach -t 0").             │
///                              └─────────────────┬───────────────────────────┘
///                                                │ %end / %error
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │           startup_session                   │
///                              │                                             │
///                              │  Wait for %session-changed notification     │
///                              │  to get the initial session ID.             │
///                              └─────────────────┬───────────────────────────┘
///                                                │ %session-changed
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │           command_queue                     │
///                              │                                             │
///                              │  Main operating state. Process commands     │
///                              │  sequentially and handle notifications.     │
///                              └─────────────────────────────────────────────┘
///                                                │
///                    ┌───────────────────────────┼───────────────────────────┐
///                    │                           │                           │
///                    ▼                           ▼                           ▼
///     ┌──────────────────────────┐ ┌──────────────────────────┐ ┌────────────────────────┐
///     │     tmux_version         │ │     list_windows         │ │   %output / %layout-   │
///     │                          │ │                          │ │   change / etc.        │
///     │  Query tmux version for  │ │  Get all windows in the  │ │                        │
///     │  compatibility checks.   │ │  current session.        │ │  Handle live updates   │
///     └──────────────────────────┘ └────────────┬─────────────┘ │  from tmux server.     │
///                                               │               └────────────────────────┘
///                                               ▼
///                              ┌─────────────────────────────────────────────┐
///                              │          syncLayouts                        │
///                              │                                             │
///                              │  For each window, parse layout and sync     │
///                              │  panes. New panes trigger capture commands. │
///                              └─────────────────┬───────────────────────────┘
///                                                │
///                    ┌───────────────────────────┴───────────────────────────┐
///                    │                  For each new pane:                   │
///                    ▼                                                       ▼
///     ┌──────────────────────────┐                            ┌──────────────────────────┐
///     │     pane_history         │                            │     pane_visible         │
///     │     (primary screen)     │                            │     (primary screen)     │
///     │                          │                            │                          │
///     │  Capture scrollback      │                            │  Capture visible area    │
///     │  history into terminal.  │                            │  into terminal.          │
///     └──────────────────────────┘                            └──────────────────────────┘
///                    │                                                       │
///                    ▼                                                       ▼
///     ┌──────────────────────────┐                            ┌──────────────────────────┐
///     │     pane_history         │                            │     pane_visible         │
///     │     (alternate screen)   │                            │     (alternate screen)   │
///     └──────────────────────────┘                            └──────────────────────────┘
///                    │                                                       │
///                    └───────────────────────────┬───────────────────────────┘
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │          pane_state                         │
///                              │                                             │
///                              │  Query cursor position, cursor style,       │
///                              │  and alternate screen mode for all panes.   │
///                              └─────────────────────────────────────────────┘
///                                                │
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │        READY FOR OPERATION                  │
///                              │                                             │
///                              │  Panes are populated with content. The      │
///                              │  viewer handles %output for live updates,   │
///                              │  %layout-change for pane changes, and       │
///                              │  %session-changed for session switches.     │
///                              └─────────────────────────────────────────────┘
/// ```
///
/// ## Error Handling
///
/// At any point, if an unrecoverable error occurs or tmux sends `%exit`,
/// the viewer transitions to the `defunct` state and emits an `.exit` action.
///
/// ## Session Changes
///
/// When `%session-changed` is received during `command_queue` state, the
/// viewer resets itself completely: clears all windows/panes, emits an
/// empty windows action, and restarts the `list_windows` flow for the new
/// session. A command that is already in flight keeps its place at the
/// head of the queue so its reply isn't taken for the new list.
///
/// ## Reply Attribution
///
/// tmux answers every command in order, so replies are matched to the
/// command queue by position. Two things would break that and are
/// handled explicitly: blocks tmux writes for hooks (their `%begin`
/// flags say they aren't ours, see `control.Block.client`) and user
/// command lines that get any number of blocks (see `Command.User`).
///
pub const Viewer = struct {
    /// I/O implementation used for all internal state.
    io: std.Io,

    /// Allocator used for all internal state.
    alloc: Allocator,

    /// Current state of the state machine.
    state: State,

    /// The current session ID we're attached to.
    session_id: usize,

    /// The tmux server version string (e.g., "3.5a"). We capture this
    /// on startup because it will allow us to change behavior between
    /// versions as necessary.
    tmux_version: []const u8,

    /// The list of commands we've sent that we want to send and wait
    /// for a response for. We only send one command at a time just
    /// to avoid any possible confusion around ordering.
    command_queue: CommandQueue,

    /// The windows in the current session.
    windows: std.ArrayList(Window),

    /// The panes in the current session, mapped by pane ID. Empty unless
    /// `mirror_panes` is set.
    panes: PanesMap,

    /// Whether every pane gets a terminal of its own here, filled from
    /// tmux and kept up to date from `%output`. An embedder that shows
    /// each pane in a view of its own, which asks for a pane's contents
    /// with `capturePane`, turns this off so that pane output isn't
    /// parsed twice.
    mirror_panes: bool = true,

    /// What `capturePane` gathered so far for the view whose capture is
    /// in flight. Its replies arrive one right after another, and the
    /// last one sends the `pane_restore` action.
    restore: ?PendingRestore = null,

    /// The arena used for the prior action allocated state. This contains
    /// the contents for the actions as well as the actions slice itself.
    action_arena: ArenaAllocator.State,

    /// A single action pre-allocated that we use for single-action
    /// returns (common). This ensures that we can never get allocation
    /// errors on single-action returns, especially those such as `.exit`.
    action_single: [1]Action,

    /// Numbers the end markers of user commands. See `Command.User`.
    user_command_id: u32 = 0,

    pub const CommandQueue = CircBuf(Command, undefined);
    pub const PanesMap = std.AutoArrayHashMapUnmanaged(usize, Pane);

    pub const Action = union(enum) {
        /// Tmux has closed the control mode connection, we should end
        /// our viewer session in some way.
        exit,

        /// Send a command to tmux, e.g. `list-windows`. The caller
        /// should not worry about parsing this or reading what command
        /// it is; just send it to tmux as-is. This will include the
        /// trailing newline so you can send it directly.
        command: []const u8,

        /// Windows changed. This may add, remove or change windows. The
        /// caller is responsible for diffing the new window list against
        /// the prior one. Remember that for a given Viewer, window IDs
        /// are guaranteed to be stable. Additionally, tmux (as of Dec 2025)
        /// never reuses window IDs within a server process lifetime.
        windows: []const Window,

        /// The session's current window changed (`%session-window-changed`
        /// for our session), including from an external `select-window`.
        /// The window may not be in the window list yet: tmux announces
        /// a new window as current before it announces the window.
        active_window: usize,

        /// The active pane of one of our windows changed
        /// (`%window-pane-changed`). This doesn't make the window the
        /// current one.
        active_pane: ActivePane,

        /// One of our windows was renamed. The name is only valid until
        /// the next call into the viewer.
        window_renamed: WindowRenamed,

        /// What a newly created view of a pane needs to show the pane the
        /// way tmux has it, in response to `capturePane`. Only valid until
        /// the next call into the viewer. See `writePaneRestore`.
        pane_restore: PaneRestore,

        pub const PaneRestore = struct {
            pane_id: usize,

            /// The contents of the primary and the alternate screen,
            /// decoded. The alternate screen's only matters when the pane
            /// is on it.
            primary: []const u8,
            alternate: []const u8,

            /// The pane's modes, cursor and scroll region.
            state: PaneState,
        };

        pub const ActivePane = struct {
            window_id: usize,
            pane_id: usize,
        };

        pub const WindowRenamed = struct {
            window_id: usize,
            name: []const u8,
        };

        pub fn format(self: Action, writer: *std.Io.Writer) !void {
            const T = Action;
            const info = @typeInfo(T).@"union";

            try writer.writeAll(@typeName(T));
            if (info.tag_type) |TagType| {
                try writer.writeAll("{ .");
                try writer.writeAll(@tagName(@as(TagType, self)));
                try writer.writeAll(" = ");

                inline for (info.field_names, info.field_types) |field_name, field_type| {
                    if (self == @field(TagType, field_name)) {
                        const value = @field(self, field_name);
                        switch (field_type) {
                            []const u8 => try writer.print("\"{s}\"", .{std.mem.trim(u8, value, " \t\r\n")}),
                            // Window embeds ArenaAllocator.State; dumping
                            // `{any}` walks freed/poisoned arena nodes.
                            []const Window => try writer.print("[{d} windows]", .{value.len}),
                            PaneRestore => try writer.print(
                                "%{d} ({d}+{d} bytes)",
                                .{ value.pane_id, value.primary.len, value.alternate.len },
                            ),
                            WindowRenamed => try writer.print(
                                "@{d} \"{s}\"",
                                .{ value.window_id, value.name },
                            ),
                            else => try writer.print("{any}", .{value}),
                        }
                    }
                }

                try writer.writeAll(" }");
            }
        }
    };

    pub const Input = union(enum) {
        /// Data from tmux was received that needs to be processed.
        tmux: control.Notification,
    };

    pub const Window = struct {
        id: usize,

        /// The window's index in the session. This is what tmux orders
        /// windows by in its status line; it isn't stable across
        /// `move-window` / `swap-window` the way the id is.
        index: usize,

        /// Owned by the viewer allocator.
        name: []const u8,

        /// True for the session's current window.
        active: bool,

        /// True while one pane is zoomed to fill the window. `layout`
        /// stays the full layout; `visible_layout` is what tmux shows.
        zoomed: bool,

        /// The window's active pane.
        active_pane: usize,

        width: usize,
        height: usize,

        /// Owned by the viewer allocator.
        affinities: []const u8,

        /// Holds `layout` and `visible_layout`.
        layout_arena: ArenaAllocator.State,
        layout: Layout,

        /// The layout tmux shows while the window is zoomed: only the
        /// zoomed pane, at the full window size. Null when not zoomed.
        visible_layout: ?Layout,

        pub fn deinit(self: *Window, alloc: Allocator) void {
            alloc.free(self.name);
            alloc.free(self.affinities);
            self.layout_arena.promote(alloc).deinit();
        }
    };

    /// A pane's modes, cursor and scroll region as tmux reports them.
    pub const PaneState = Format.list_panes.Struct();

    /// See `restore`. The contents are decoded and owned by the viewer.
    const PendingRestore = struct {
        pane_id: usize,
        primary: []u8 = &.{},
        alternate: []u8 = &.{},

        fn deinit(self: *PendingRestore, alloc: Allocator) void {
            alloc.free(self.primary);
            alloc.free(self.alternate);
        }
    };

    pub const Pane = struct {
        terminal: Terminal,
        output_stream: ?*TerminalStream = null,

        fn outputStream(self: *Pane, alloc: Allocator) Allocator.Error!*TerminalStream {
            if (self.output_stream == null) {
                const stream = try alloc.create(TerminalStream);
                stream.* = self.terminal.vtStream();
                self.output_stream = stream;
            }

            const stream = self.output_stream.?;
            // Pane values can move when the pane map is rebuilt.
            stream.handler.terminal = &self.terminal;
            return stream;
        }

        pub fn deinit(self: *Pane, alloc: Allocator) void {
            if (self.output_stream) |stream| {
                // The pane may have moved since its last output.
                stream.handler.terminal = &self.terminal;
                stream.deinit();
                alloc.destroy(stream);
            }
            self.terminal.deinit(alloc);
        }
    };

    /// Initialize a new viewer.
    ///
    /// The given allocator is used for all internal state. You must
    /// call deinit when you're done with the viewer to free it.
    pub fn init(io: std.Io, alloc: Allocator) Allocator.Error!Viewer {
        // Create our initial command queue
        var command_queue: CommandQueue = try .init(alloc, COMMAND_QUEUE_INITIAL);
        errdefer command_queue.deinit(alloc);

        return .{
            .io = io,
            .alloc = alloc,
            .state = .startup_block,
            // The default value here is meaningless. We don't get started
            // until we receive a session-changed notification which will
            // set this to a real value.
            .session_id = 0,
            .tmux_version = "",
            .command_queue = command_queue,
            .windows = .empty,
            .panes = .empty,
            .action_arena = .{},
            .action_single = undefined,
        };
    }

    pub fn deinit(self: *Viewer) void {
        {
            for (self.windows.items) |*window| window.deinit(self.alloc);
            self.windows.deinit(self.alloc);
        }
        {
            var it = self.command_queue.iterator(.forward);
            while (it.next()) |command| command.deinit(self.alloc);
            self.command_queue.deinit(self.alloc);
        }
        {
            var it = self.panes.iterator();
            while (it.next()) |kv| kv.value_ptr.deinit(self.alloc);
            self.panes.deinit(self.alloc);
        }
        if (self.restore) |*v| v.deinit(self.alloc);
        if (self.tmux_version.len > 0) {
            self.alloc.free(self.tmux_version);
        }
        self.action_arena.promote(self.alloc).deinit();
    }

    /// Send in an input event (such as a tmux protocol notification,
    /// keyboard input for a pane, etc.) and process it. The returned
    /// list is a set of actions to take as a result of the input prior
    /// to the next input. This list may be empty.
    pub fn next(self: *Viewer, input: Input) []const Action {
        // Developer note: this function must never return an error. If
        // an error occurs we must go into a defunct state or some other
        // state to gracefully handle it.
        return switch (input) {
            .tmux => self.nextTmux(input.tmux),
        };
    }

    /// Send a command that didn't originate from the viewer (e.g. one the
    /// user typed, or a split created from the GUI). The command must
    /// include its trailing newline.
    ///
    /// Commands can't just be written to the pty directly: tmux answers
    /// every command with a `%begin`/`%end` block and we match those
    /// blocks against our command queue in order, so an out-of-band
    /// command would shift every later block onto the wrong command.
    ///
    /// A line can be answered with any number of blocks: `a ; b` gets
    /// one per command (up to the first that fails), `if-shell` adds the
    /// blocks of what it runs, a comment gets none. So the line is
    /// followed by an end marker of our own (see `Command.User`) and
    /// everything up to the marker's block belongs to this command.
    ///
    /// The returned actions must be processed the same way as those from
    /// `next`, and are only valid until the next call into the viewer.
    pub fn sendCommand(self: *Viewer, command: []const u8) []const Action {
        assert(command.len > 0);
        assert(command[command.len - 1] == '\n');

        // We can only interleave with the command queue once we're in it.
        // Startup is a handful of round trips so dropping is fine.
        if (self.state != .command_queue) {
            log.info("dropping command sent outside the command queue", .{});
            return &.{};
        }

        const id = self.user_command_id;
        self.user_command_id +%= 1;
        const owned = std.fmt.allocPrint(
            self.alloc,
            "{s}" ++ Command.User.marker_command,
            .{ command, id },
        ) catch {
            log.warn("failed to allocate command, dropping", .{});
            return &.{};
        };

        // If nothing is in flight we have to send this ourselves,
        // otherwise the queue will send it when its turn comes.
        const send = self.command_queue.empty();
        self.queueCommands(&.{.{ .user = .{ .line = owned, .id = id } }}) catch {
            log.warn("failed to queue command, dropping", .{});
            self.alloc.free(owned);
            return &.{};
        };

        // The queue owns `owned` until the matching block arrives, so
        // this stays valid for as long as the action is.
        return if (send) self.singleAction(.{ .command = owned }) else &.{};
    }

    /// The name of the subscription that `windows_subscription_command`
    /// sets up.
    pub const windows_subscription = "ghostty-windows";

    /// Subscribe to the order of the session's windows. tmux sends no
    /// notification at all when `swap-window` or `move-window -r` reorders
    /// windows, but the value of this format changes, and tmux reports
    /// that with `%subscription-changed` (checked about once a second).
    /// We then list the windows again. Sent through `sendCommand`;
    /// subscriptions need tmux 3.2, and older versions just reply with an
    /// error.
    pub const windows_subscription_command =
        "refresh-client -B '" ++ windows_subscription ++ "::#{W:#{window_id} }'\n";

    /// List the windows again, for example after the caller reordered
    /// them, so that the order arrives without waiting for the
    /// subscription. Returns the actions to process, like `next`.
    pub fn refreshWindows(self: *Viewer) []const Action {
        if (self.state != .command_queue) {
            log.info("dropping window refresh outside the command queue", .{});
            return &.{};
        }

        // Formatted before it is queued: a queued command that can't be
        // sent would hold up the queue for good.
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        var builder: std.Io.Writer.Allocating = .init(arena.allocator());
        const command: Command = .list_windows;
        command.formatCommand(&builder.writer) catch {
            log.warn("failed to format list-windows, dropping", .{});
            return &.{};
        };

        const send = self.command_queue.empty();
        self.queueListWindows() catch {
            log.warn("failed to queue window refresh, dropping", .{});
            return &.{};
        };
        if (!send) return &.{};
        return self.singleAction(.{ .command = builder.writer.buffered() });
    }

    /// The caller is detaching by writing to tmux directly. tmux answers
    /// those writes too, so from now on nothing it sends is matched
    /// against our queue; we only wait for the caller to see `%exit`.
    pub fn detach(self: *Viewer) void {
        self.state = .defunct;
    }

    /// Ask tmux for the current contents and modes of a pane. The answer
    /// comes back as a `pane_restore` action.
    ///
    /// This is how a newly created view of a pane gets what was already on
    /// screen; `%output` only carries what happens from now on.
    pub fn capturePane(self: *Viewer, pane_id: usize) []const Action {
        if (self.state != .command_queue) {
            log.info("dropping capture-pane sent outside the command queue", .{});
            return &.{};
        }

        // Three commands rather than a `;` sequence because tmux wraps
        // every command of a sequence in its own begin/end block, which
        // our queue matches one-to-one. They are queued together, so
        // their replies arrive one right after another.
        const command: Command = .{ .follower_capture = .{
            .id = pane_id,
            .screen_key = .primary,
        } };
        const send = self.command_queue.empty();
        self.queueCommands(&.{
            command,
            .{ .follower_capture = .{ .id = pane_id, .screen_key = .alternate } },
            .{ .follower_state = pane_id },
        }) catch {
            log.warn("failed to queue capture-pane, dropping", .{});
            return &.{};
        };
        if (!send) return &.{};

        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        var builder: std.Io.Writer.Allocating = .init(arena.allocator());
        command.formatCommand(&builder.writer) catch {
            log.warn("failed to format capture-pane, dropping", .{});
            return &.{};
        };

        return self.singleAction(.{ .command = builder.writer.buffered() });
    }

    fn nextTmux(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        return switch (self.state) {
            .defunct => defunct: {
                log.info("received notification in defunct state, ignoring", .{});
                break :defunct &.{};
            },

            .startup_block => self.nextStartupBlock(n),
            .startup_session => self.nextStartupSession(n),
            .command_queue => self.nextCommand(n),
        };
    }

    fn nextStartupBlock(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .startup_block);

        switch (n) {
            // This is only sent by the DCS parser when we first get
            // DCS 1000p, it should never reach us here.
            .enter => unreachable,

            // I don't think this is technically possible (reading the
            // tmux source code), but if we see an exit we can semantically
            // handle this without issue.
            .exit => return self.defunct(),

            // Any begin and end (even error) is fine! Now we wait for
            // session-changed to get the initial session ID. session-changed
            // is guaranteed to come after the initial command output
            // since if the initial command is `attach` tmux will run that,
            // queue the notification, then do notificatins.
            .block_end, .block_err => {
                self.state = .startup_session;
                return &.{};
            },

            // I don't like catch-all else branches but startup is such
            // a special case of looking for very specific things that
            // are unlikely to expand.
            else => return &.{},
        }
    }

    fn nextStartupSession(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .startup_session);

        switch (n) {
            .enter => unreachable,

            .exit => return self.defunct(),

            .session_changed => |info| {
                self.session_id = info.id;

                var arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = arena.state;
                _ = arena.reset(.free_all);

                return self.enterCommandQueue(
                    arena.allocator(),
                    &.{ .tmux_version, .list_windows },
                ) catch {
                    log.warn("failed to queue command, becoming defunct", .{});
                    return self.defunct();
                };
            },

            else => return &.{},
        }
    }

    fn nextIdle(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .idle);

        switch (n) {
            .enter => unreachable,
            .exit => return self.defunct(),
            else => return &.{},
        }
    }

    fn nextCommand(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        // We have to be in a command queue, but the command queue MAY
        // be empty. If it is empty, then receivedCommandOutput will
        // handle it by ignoring any command output. That's okay!
        assert(self.state == .command_queue);

        // Clear our prior arena so it is ready to be used for any
        // actions immediately.
        {
            var arena = self.action_arena.promote(self.alloc);
            _ = arena.reset(.free_all);
            self.action_arena = arena.state;
        }

        // Setup our empty actions list that commands can populate.
        var actions: std.ArrayList(Action) = .empty;

        // Track whether the in-flight command slot is available. Starts true
        // if queue is empty (no command in flight). Set to true when a command
        // completes (block_end/block_err) or the queue is reset (session_changed).
        var command_consumed = self.command_queue.empty();

        switch (n) {
            .enter => unreachable,
            .exit => return self.defunct(),

            inline .block_end,
            .block_err,
            => |block, tag| if (!block.client) {
                // tmux writes the output of hooks to us too, but it
                // isn't the reply to anything we sent. Matching it
                // against the queue would shift every later reply onto
                // the wrong command.
                log.debug("ignoring tmux block we didn't send data={s}", .{block.data});
            } else {
                const finished = self.receivedCommandOutput(
                    &actions,
                    block,
                    tag == .block_err,
                ) catch {
                    log.warn("failed to process command output, becoming defunct", .{});
                    return self.defunct();
                };

                // The in-flight command is done unless it's a user
                // command still waiting for its end marker.
                if (finished) command_consumed = true;
            },

            .output => |out| self.receivedOutput(
                out.pane_id,
                out.data,
            ) catch |err| {
                log.warn(
                    "failed to process output for pane id={}: {}",
                    .{ out.pane_id, err },
                );
            },

            // Session changed means we switched to a different tmux session.
            // We need to reset our state and start fresh with list-windows.
            // This completely replaces the viewer, so treat it like a fresh start.
            .session_changed => |info| {
                const idle = self.sessionChanged(
                    &actions,
                    info.id,
                ) catch {
                    log.warn("failed to handle session change, becoming defunct", .{});
                    return self.defunct();
                };

                // The queue was rebuilt. If a command was in flight it
                // still is, and the next one goes out after its reply.
                command_consumed = idle;
            },

            // Layout changed of a single window.
            .layout_change => |info| self.layoutChanged(
                &actions,
                info.window_id,
                info.layout,
                info.visible_layout,
                info.raw_flags,
            ) catch {
                // Note: in the future, we can probably handle a failure
                // here with a fallback to remove this one window, list
                // windows again, and try again.
                log.warn("failed to handle layout change, becoming defunct", .{});
                return self.defunct();
            },

            // A window was added to this session.
            .window_add => |info| self.windowAdd(info.id) catch {
                log.warn("failed to handle window add, becoming defunct", .{});
                return self.defunct();
            },

            // A window was closed. Refresh the window list so the GUI
            // drops the native surface and updates @affinities.
            .window_close => |info| self.windowClose(info.id) catch {
                log.warn("failed to handle window close, becoming defunct", .{});
                return self.defunct();
            },

            // These are mostly about other sessions' windows, but tmux
            // also uses the "unlinked" form for one of our windows that
            // is already gone from our session when it notifies (a
            // killed window, a window whose last pane exited, a window
            // moved to another session). Only those concern us.
            inline .unlinked_window_add,
            .unlinked_window_close,
            => |info| if (self.findWindow(info.id) != null) {
                self.queueListWindows() catch {
                    log.warn("failed to queue window refresh, becoming defunct", .{});
                    return self.defunct();
                };
            },

            // tmux tells every control client about every session's
            // current window, so only our own session's matters.
            .session_window_changed => |info| if (info.session_id == self.session_id) {
                for (self.windows.items) |*window| {
                    window.active = window.id == info.window_id;
                }
                self.appendAction(&actions, .{
                    .active_window = info.window_id,
                }) catch |err| {
                    log.warn("failed to report active tmux window err={}", .{err});
                };
            },

            // Also sent for every session's windows, and for select-pane
            // in a window that isn't the current one.
            .window_pane_changed => |info| if (self.findWindow(info.window_id)) |window| {
                window.active_pane = info.pane_id;
                self.appendAction(&actions, .{ .active_pane = .{
                    .window_id = info.window_id,
                    .pane_id = info.pane_id,
                } }) catch |err| {
                    log.warn("failed to report active tmux pane err={}", .{err});
                };
            },

            // Only renames of our own windows matter. The "unlinked" form
            // is normally about another session's window, but as with the
            // closes above the name alone doesn't settle it, so both forms
            // go through the id check.
            inline .window_renamed,
            .unlinked_window_renamed,
            => |info| self.windowRenamed(
                &actions,
                info.id,
                info.name,
            ) catch |err| {
                log.warn("failed to rename tmux window err={}", .{err});
            },

            // We ignore this one. It means a session was created or
            // destroyed. If it was our own session we will get an exit
            // notification very soon. If it is another session we don't
            // care.
            .sessions_changed => {},

            // Nothing we mirror depends on the session name or on panes
            // entering copy mode.
            .session_renamed,
            .pane_mode_changed,
            => {},

            // The order of our windows changed in a way tmux sends no
            // other notification for. See `windows_subscription_command`.
            .subscription_changed => |info| if (std.mem.eql(
                u8,
                info.name,
                windows_subscription,
            )) {
                self.queueListWindows() catch {
                    log.warn("failed to queue window refresh, becoming defunct", .{});
                    return self.defunct();
                };
            },

            // This is for other clients, which we don't do anything about.
            // For us, we'll get `exit` or `session_changed`, respectively.
            .client_detached,
            .client_session_changed,
            => {},
        }

        // After processing commands, we add our next command to
        // execute if we have one. We do this last because command
        // processing may itself queue more commands. We only emit a
        // command if a prior command was consumed (or never existed).
        if (self.state == .command_queue and command_consumed) {
            if (self.command_queue.first()) |next_command| {
                // We should not have any commands, because our nextCommand
                // always queues them.
                if (comptime std.debug.runtime_safety) {
                    for (actions.items) |action| {
                        if (action == .command) assert(false);
                    }
                }

                var arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = arena.state;
                const arena_alloc = arena.allocator();

                var builder: std.Io.Writer.Allocating = .init(arena_alloc);
                next_command.formatCommand(&builder.writer) catch
                    return self.defunct();
                actions.append(
                    arena_alloc,
                    .{ .command = builder.writer.buffered() },
                ) catch return self.defunct();
            }
        }

        return actions.items;
    }

    /// When the layout changes for a single window, a pane may be added
    /// or removed that we've never seen, in addition to the layout itself
    /// physically changing.
    ///
    /// To handle this, its similar to list-windows except we expect the
    /// window to already exist. We update the layout, do the initLayout
    /// call for any diffs, setup commands to capture any new panes,
    /// prune any removed panes.
    fn layoutChanged(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        window_id: usize,
        layout_str: []const u8,
        visible_layout_str: []const u8,
        raw_flags: []const u8,
    ) !void {
        // Find the window this layout change is for.
        const window: *Window = self.findWindow(window_id) orelse {
            log.info("layout change for unknown window id={}", .{window_id});
            return;
        };

        // tmux marks a zoomed window with 'Z' in its flags. The layout
        // is then still the full one and the visible layout is the
        // zoomed pane alone.
        const zoomed = std.mem.indexOfScalar(u8, raw_flags, 'Z') != null;

        // Parse into a new arena so the window keeps a valid layout if
        // this fails.
        var layout_arena: ArenaAllocator = .init(self.alloc);
        const layout: Layout, const visible_layout: ?Layout = parsed: {
            errdefer layout_arena.deinit();
            const full = Layout.parseWithChecksum(
                layout_arena.allocator(),
                layout_str,
            ) catch |err| {
                log.info(
                    "failed to parse window layout id={} layout={s}",
                    .{ window_id, layout_str },
                );
                return err;
            };
            const visible: ?Layout = if (zoomed) Layout.parseWithChecksum(
                layout_arena.allocator(),
                visible_layout_str,
            ) catch |err| {
                log.info(
                    "failed to parse visible window layout id={} layout={s}",
                    .{ window_id, visible_layout_str },
                );
                return err;
            } else null;
            break :parsed .{ full, visible };
        };

        window.layout_arena.promote(self.alloc).deinit();
        window.layout_arena = layout_arena.state;
        window.layout = layout;
        window.visible_layout = visible_layout;
        window.zoomed = zoomed;

        // The layout root is the whole window, so this is also how the
        // window size reaches us after a resize.
        window.width = layout.width;
        window.height = layout.height;

        // Reset our arena so we can build up actions.
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        const arena_alloc = arena.allocator();

        // Our initial action is to definitely let the caller know that
        // some windows changed.
        try actions.append(arena_alloc, .{ .windows = self.windows.items });

        // Sync up our panes
        try self.syncLayouts(self.windows.items);
    }

    /// Rename one of our windows. Windows of other sessions are ignored.
    fn windowRenamed(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        window_id: usize,
        name: []const u8,
    ) Allocator.Error!void {
        const window = self.findWindow(window_id) orelse return;
        const owned = try self.alloc.dupe(u8, name);
        self.alloc.free(window.name);
        window.name = owned;
        try self.appendAction(actions, .{ .window_renamed = .{
            .window_id = window_id,
            .name = window.name,
        } });
    }

    fn findWindow(self: *Viewer, window_id: usize) ?*Window {
        for (self.windows.items) |*window| {
            if (window.id == window_id) return window;
        }

        return null;
    }

    /// Append an action allocated in the action arena.
    fn appendAction(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        action: Action,
    ) Allocator.Error!void {
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        try actions.append(arena.allocator(), action);
    }

    /// When a window is added to the session, we need to refresh our window
    /// list to get the new window's information.
    fn windowAdd(
        self: *Viewer,
        window_id: usize,
    ) !void {
        _ = window_id; // We refresh all windows via list-windows

        // Queue list-windows to get the updated window list
        try self.queueListWindows();
    }

    /// When a window is closed, refresh the list so removed windows
    /// disappear from the GUI and from `@affinities`.
    fn windowClose(
        self: *Viewer,
        window_id: usize,
    ) !void {
        _ = window_id;
        try self.queueListWindows();
    }

    fn syncLayouts(
        self: *Viewer,
        windows: []const Window,
    ) !void {
        // Go through the window layout and setup all our panes. We move
        // this into a new panes map so that we can easily prune our old
        // list.
        var panes: PanesMap = .empty;
        errdefer {
            // Clear out all the new panes.
            var panes_it = panes.iterator();
            while (panes_it.next()) |kv| {
                if (!self.panes.contains(kv.key_ptr.*)) {
                    kv.value_ptr.deinit(self.alloc);
                }
            }
            panes.deinit(self.alloc);
        }
        for (windows) |window| try initLayout(
            self.io,
            self.alloc,
            &self.panes,
            if (self.mirror_panes) &panes else null,
            window.layout,
        );

        // Build up the list of removed panes.
        var removed: std.ArrayList(usize) = removed: {
            var removed: std.ArrayList(usize) = .empty;
            errdefer removed.deinit(self.alloc);
            var panes_it = self.panes.iterator();
            while (panes_it.next()) |kv| {
                if (panes.contains(kv.key_ptr.*)) continue;
                try removed.append(self.alloc, kv.key_ptr.*);
            }

            break :removed removed;
        };
        defer removed.deinit(self.alloc);

        // Ensure we can add the windows
        try self.windows.ensureTotalCapacity(self.alloc, windows.len);

        // Get our list of added panes and setup our command queue
        // to populate them.
        // TODO: errdefer cleanup
        {
            var panes_it = panes.iterator();
            var added: bool = false;
            while (panes_it.next()) |kv| {
                const pane_id: usize = kv.key_ptr.*;
                if (self.panes.contains(pane_id)) continue;
                added = true;
                try self.queueCommands(&.{
                    .{ .pane_history = .{ .id = pane_id, .screen_key = .primary } },
                    .{ .pane_visible = .{ .id = pane_id, .screen_key = .primary } },
                    .{ .pane_history = .{ .id = pane_id, .screen_key = .alternate } },
                    .{ .pane_visible = .{ .id = pane_id, .screen_key = .alternate } },
                });
            }

            // If we added any panes, then we also want to resync the pane
            // state (terminal modes and cursor positions and so on).
            if (added) try self.queueCommands(&.{.pane_state});
        }

        // No more errors after this point. We're about to replace all
        // our owned state with our temporary state, and our errdefers
        // above will double-free if there is an error.
        errdefer comptime unreachable;

        // Replace our window list if it changed. We assume it didn't
        // change if our pointer is pointing to the same data.
        if (windows.ptr != self.windows.items.ptr) {
            for (self.windows.items) |*window| window.deinit(self.alloc);
            self.windows.clearRetainingCapacity();
            self.windows.appendSliceAssumeCapacity(windows);
        }

        // Replace our panes
        {
            // First remove our old panes
            for (removed.items) |id| if (self.panes.fetchSwapRemove(
                id,
            )) |entry_const| {
                var entry = entry_const;
                entry.value.deinit(self.alloc);
            };
            // We can now deinit self.panes because the existing
            // entries are preserved.
            self.panes.deinit(self.alloc);
            self.panes = panes;
        }
    }

    /// When a session changes, we have to basically reset our whole state.
    /// To do this, we emit an empty windows event (so callers can clear all
    /// windows), reset ourself, and start all over.
    ///
    /// Returns true if no command is in flight, i.e. the first command of
    /// the new queue has to be sent now.
    fn sessionChanged(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        session_id: usize,
    ) (Allocator.Error || std.Io.Writer.Error)!bool {
        // Build up a new viewer. Its the easiest way to reset ourselves.
        var replacement: Viewer = try .init(self.io, self.alloc);
        errdefer replacement.deinit();

        // Our actions must start out empty so we don't mix arenas
        assert(actions.items.len == 0);
        errdefer actions.* = .empty;

        // Build actions: empty windows notification + list-windows command
        var arena = replacement.action_arena.promote(replacement.alloc);
        const arena_alloc = arena.allocator();
        try actions.append(arena_alloc, .{ .windows = &.{} });

        // Carry over the commands that still matter:
        //
        // - The head of the queue, if any, was already sent. Its reply is
        //   still coming and has to be matched against it, not against
        //   the list-windows below. If it's one of ours it was about the
        //   old session, so its reply is dropped.
        // - User commands asked for something explicit and address panes
        //   and windows by id, so they still go out (and a user command
        //   can be what switched the session, with its end marker still
        //   to come).
        // - Our own captures and queries were for the old session's
        //   panes and are dropped.
        const idle = self.command_queue.empty();
        try replacement.command_queue.ensureUnusedCapacity(
            replacement.alloc,
            self.command_queue.len() + 1,
        );
        {
            var it = self.command_queue.iterator(.forward);
            var head = true;
            while (it.next()) |command| {
                defer head = false;
                switch (command.*) {
                    // Ownership moves to the replacement.
                    .user => {
                        replacement.command_queue.appendAssumeCapacity(command.*);
                        command.* = .stale;
                    },

                    else => if (head) {
                        replacement.command_queue.appendAssumeCapacity(.stale);
                    },
                }

                if (head) replacement.command_queue.appendAssumeCapacity(.list_windows);
            }
        }
        if (idle) replacement.command_queue.appendAssumeCapacity(.list_windows);
        replacement.state = .command_queue;

        // Transfer preserved state to replacement
        replacement.tmux_version = try replacement.alloc.dupe(u8, self.tmux_version);
        replacement.user_command_id = self.user_command_id;

        // Save arena state back before swap
        replacement.action_arena = arena.state;

        // Swap our self, no more error handling after this.
        errdefer comptime unreachable;
        self.deinit();
        self.* = replacement;

        // Set our session ID and jump directly to the list
        self.session_id = session_id;

        assert(self.state == .command_queue);
        return idle;
    }

    /// Handle a block that answers the command at the head of the queue.
    /// Returns true if that command is done and was removed from the
    /// queue; a user command stays until its end marker arrives.
    fn receivedCommandOutput(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        block: control.Block,
        is_err: bool,
    ) !bool {
        const head = self.command_queue.first() orelse {
            // If we have no pending commands, this is unexpected.
            log.info("unexpected block output err={}", .{is_err});
            return false;
        };

        // Every block up to the end marker belongs to the user's line.
        // We don't use their output; failures were already logged.
        switch (head.*) {
            .user => |user| if (!user.isEnd(block.data)) return false,
            else => {},
        }

        // Get the command we're expecting output for. We need to get the
        // non-pointer value because we are deleting it from the circular
        // buffer immediately. This shallow copy is all we need since
        // all the memory in Command is owned by GPA.
        const command: Command = switch (head.*) {
            // I truly can't explain this. A simple `ptr.*` copy will cause
            // our memory to become undefined when deleteOldest is called
            // below. I logged all the pointers and they don't match so I
            // don't know how its being set to undefined. But a copy like
            // this does work.
            inline else => |v, tag| @unionInit(
                Command,
                @tagName(tag),
                v,
            ),
        };
        self.command_queue.deleteOldest(1);
        defer command.deinit(self.alloc);

        // A failed command has tmux's error message where its output
        // would be (a pane closed before we captured it, say), and a
        // truncated one has nothing at all. Neither can be used as
        // output, but neither breaks anything else either.
        if (is_err or block.truncated) {
            log.info(
                "tmux command got no usable output command={t} err={} truncated={} output={s}",
                .{ command, is_err, block.truncated, block.data },
            );
            return true;
        }
        const content = block.data;

        // We'll use our arena for the return value here so we can
        // easily accumulate actions.
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        const arena_alloc = arena.allocator();

        // Process our command
        switch (command) {
            .user, .stale => {},

            .follower_capture => |cap| try self.receivedFollowerCapture(cap, content),

            .follower_state => |id| try self.receivedFollowerState(
                arena_alloc,
                actions,
                id,
                content,
            ),

            .pane_state => try self.receivedPaneState(content),

            .list_windows => try self.receivedListWindows(
                arena_alloc,
                actions,
                content,
            ),

            .pane_history => |cap| try self.receivedPaneHistory(
                cap.screen_key,
                cap.id,
                try control.unescapeAlloc(arena_alloc, content),
            ),

            .pane_visible => |cap| try self.receivedPaneVisible(
                cap.screen_key,
                cap.id,
                try control.unescapeAlloc(arena_alloc, content),
            ),

            .tmux_version => try self.receivedTmuxVersion(content),
        }

        return true;
    }

    fn receivedTmuxVersion(
        self: *Viewer,
        content: []const u8,
    ) !void {
        const line = std.mem.trim(u8, content, " \t\r\n");
        if (line.len == 0) return;

        const data = output.parseFormatStruct(
            Format.tmux_version.Struct(),
            line,
            Format.tmux_version.delim,
        ) catch {
            // Nothing depends on knowing the version yet.
            log.info("failed to parse tmux version: {s}", .{line});
            return;
        };

        if (self.tmux_version.len > 0) {
            self.alloc.free(self.tmux_version);
        }
        self.tmux_version = try self.alloc.dupe(u8, data.version);
    }

    /// Replace our windows with a `list-windows` reply. If the reply
    /// can't be used we keep the windows we have: they are still
    /// consistent, and the next window notification refreshes them again.
    fn receivedListWindows(
        self: *Viewer,
        arena_alloc: Allocator,
        actions: *std.ArrayList(Action),
        content: []const u8,
    ) Allocator.Error!void {
        // If there is an error, reset our actions to what it was before.
        const actions_len = actions.items.len;
        errdefer actions.shrinkRetainingCapacity(actions_len);

        // This stores our new window state from this list-windows output.
        // The windows are ours to free until syncLayouts takes them over.
        var windows: std.ArrayList(Window) = .empty;
        defer {
            for (windows.items) |*window| window.deinit(self.alloc);
            windows.deinit(self.alloc);
        }

        // Parse all our windows
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line_raw| {
            // Only the line ending goes: the name is the last field and
            // may end in spaces, or be empty.
            const line = std.mem.trimEnd(u8, line_raw, "\r");
            if (line.len == 0) continue;
            const data = output.parseFormatStructRest(
                Format.list_windows.Struct(),
                line,
                Format.list_windows.delim,
            ) catch {
                log.warn("failed to parse list-windows line: {s}", .{line});
                return;
            };

            var window = initWindow(self.alloc, data) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.warn(
                        "failed to parse window layout id={} layout={s} err={}",
                        .{ data.window_id, data.window_layout, err },
                    );
                    return;
                },
            };
            windows.append(self.alloc, window) catch |err| {
                window.deinit(self.alloc);
                return err;
            };
        }

        // Sync into self.windows first. The `.windows` action must point at
        // `self.windows.items` (stable for the duration of next()), not the
        // temporary list buffer which is freed by the defer above — otherwise
        // logging/formatting the action is a use-after-free.
        self.syncLayouts(windows.items) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.warn("failed to sync tmux window layouts err={}", .{err});
                return;
            },
        };
        windows.clearRetainingCapacity();
        try actions.append(arena_alloc, .{ .windows = self.windows.items });
    }

    /// Build a window from a parsed `list-windows` line. The window owns
    /// copies of everything it needs.
    fn initWindow(
        alloc: Allocator,
        data: Format.list_windows.Struct(),
    ) !Window {
        var arena: ArenaAllocator = .init(alloc);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        const layout: Layout = try .parseWithChecksum(
            arena_alloc,
            data.window_layout,
        );
        const visible_layout: ?Layout = if (data.window_zoomed_flag)
            try .parseWithChecksum(arena_alloc, data.window_visible_layout)
        else
            null;

        const name = try alloc.dupe(u8, data.window_name);
        errdefer alloc.free(name);
        const affinities = try alloc.dupe(u8, data.affinities);

        return .{
            .id = data.window_id,
            .index = data.window_index,
            .name = name,
            .active = data.window_active,
            .zoomed = data.window_zoomed_flag,
            .active_pane = data.pane_id,
            .width = data.window_width,
            .height = data.window_height,
            .affinities = affinities,
            .layout_arena = arena.state,
            .layout = layout,
            .visible_layout = visible_layout,
        };
    }

    fn receivedPaneState(
        self: *Viewer,
        content: []const u8,
    ) !void {
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;

            const data = output.parseFormatStruct(
                Format.list_panes.Struct(),
                line,
                Format.list_panes.delim,
            ) catch {
                // The pane keeps the state it has; nothing else depends
                // on this line.
                log.info("failed to parse list-panes line: {s}", .{line});
                continue;
            };

            // Get the pane for this ID
            const entry = self.panes.getEntry(data.pane_id) orelse {
                log.info("received pane state for untracked pane id={}", .{data.pane_id});
                continue;
            };
            const pane: *Pane = entry.value_ptr;
            const t: *Terminal = &pane.terminal;

            // Determine which screen to use based on alternate_on
            const screen_key: ScreenSet.Key = if (data.alternate_on) .alternate else .primary;

            // Restore the active screen reported by tmux.
            _ = try t.switchScreen(screen_key);

            // Set cursor position on the appropriate screen (tmux uses 0-based)
            if (t.screens.get(screen_key)) |screen| {
                cursor: {
                    const cursor_x = std.math.cast(
                        size.CellCountInt,
                        data.cursor_x,
                    ) orelse break :cursor;
                    const cursor_y = std.math.cast(
                        size.CellCountInt,
                        data.cursor_y,
                    ) orelse break :cursor;
                    if (cursor_x >= screen.pages.cols or
                        cursor_y >= screen.pages.rows) break :cursor;
                    screen.cursorAbsolute(cursor_x, cursor_y);
                }

                // Set cursor shape on this screen
                if (data.cursor_shape.len > 0) {
                    if (std.mem.eql(u8, data.cursor_shape, "block")) {
                        screen.cursor.cursor_style = .block;
                    } else if (std.mem.eql(u8, data.cursor_shape, "underline")) {
                        screen.cursor.cursor_style = .underline;
                    } else if (std.mem.eql(u8, data.cursor_shape, "bar")) {
                        screen.cursor.cursor_style = .bar;
                    }
                }
                // "default" or unknown: leave as-is
            }

            // Set alternate screen saved cursor position
            if (t.screens.get(.alternate)) |alt_screen| cursor: {
                const alt_x = std.math.cast(
                    size.CellCountInt,
                    data.alternate_saved_x,
                ) orelse break :cursor;
                const alt_y = std.math.cast(
                    size.CellCountInt,
                    data.alternate_saved_y,
                ) orelse break :cursor;

                // If our coordinates are outside our screen we ignore it.
                // tmux actually sends MAX_INT for when there isn't a set
                // cursor position, so this isn't theoretical.
                if (alt_x >= alt_screen.pages.cols or
                    alt_y >= alt_screen.pages.rows) break :cursor;

                alt_screen.cursorAbsolute(alt_x, alt_y);
            }

            // Set cursor visibility
            t.modes.set(.cursor_visible, data.cursor_flag);

            // Set cursor blinking
            t.modes.set(.cursor_blinking, data.cursor_blinking);

            // Terminal modes
            t.modes.set(.insert, data.insert_flag);
            t.modes.set(.wraparound, data.wrap_flag);
            t.modes.set(.keypad_keys, data.keypad_flag);
            t.modes.set(.cursor_keys, data.keypad_cursor_flag);
            t.modes.set(.origin, data.origin_flag);

            // Mouse modes
            t.modes.set(.mouse_event_any, data.mouse_all_flag);
            t.modes.set(.mouse_event_button, data.mouse_button_flag);
            t.modes.set(.mouse_event_normal, data.mouse_standard_flag);
            t.modes.set(.mouse_format_utf8, data.mouse_utf8_flag);
            t.modes.set(.mouse_format_sgr, data.mouse_sgr_flag);

            // Focus and bracketed paste
            t.modes.set(.focus_event, data.focus_flag);
            t.modes.set(.bracketed_paste, data.bracketed_paste);

            // Scroll region (tmux uses 0-based values)
            scroll: {
                const scroll_top = std.math.cast(
                    size.CellCountInt,
                    data.scroll_region_upper,
                ) orelse break :scroll;
                const scroll_bottom = std.math.cast(
                    size.CellCountInt,
                    data.scroll_region_lower,
                ) orelse break :scroll;

                // Ignore invalid regions. The terminal assumes the scroll
                // region is always within the screen bounds.
                if (scroll_top >= scroll_bottom or
                    scroll_bottom >= t.rows) break :scroll;

                t.scrolling_region.top = scroll_top;
                t.scrolling_region.bottom = scroll_bottom;
            }

            // Tab stops - parse comma-separated list and set
            t.tabstops.reset(0); // Clear all tabstops first
            if (data.pane_tabs.len > 0) {
                var tabs_it = std.mem.splitScalar(u8, data.pane_tabs, ',');
                while (tabs_it.next()) |tab_str| {
                    const col = std.fmt.parseInt(usize, tab_str, 10) catch continue;
                    const col_cell = std.math.cast(size.CellCountInt, col) orelse continue;
                    if (col_cell >= t.cols) continue;
                    t.tabstops.set(col_cell);
                }
            }
        }
    }

    /// Prepares a pane terminal's screen for content captured from tmux.
    /// `%output` for the pane can arrive before the capture's reply, so
    /// the screen may already show some of it, and that output may have
    /// set a scroll region, origin mode, a style, protection or a charset.
    /// The capture replaces all of that content. It is laid out over the
    /// whole screen from the top-left, in the default style and charset.
    const Fill = struct {
        screen: *Screen,
        region: Terminal.ScrollingRegion,
        origin: bool,
        style: Style,
        protected: bool,
        protected_mode: ansi.ProtectedMode,
        charset: Screen.CharsetState,

        fn begin(t: *Terminal) Fill {
            const screen: *Screen = t.screens.active;
            const fill: Fill = .{
                .screen = screen,
                .region = t.scrolling_region,
                .origin = t.modes.get(.origin),
                .style = screen.cursor.style,
                .protected = screen.cursor.protected,
                .protected_mode = screen.protected_mode,
                .charset = screen.charset,
            };
            t.modes.set(.origin, false);
            t.scrolling_region = .{
                .top = 0,
                .bottom = t.rows - 1,
                .left = 0,
                .right = t.cols - 1,
            };

            // Erased cells take the background of the style, and protected
            // cells survive the erase.
            screen.cursor.style = .{};
            screen.manualStyleUpdate() catch unreachable;
            screen.cursor.protected = false;
            screen.protected_mode = .off;
            screen.charset = .{};

            // Erasing below the top-left rather than the complete display:
            // at a prompt, a complete erase scrolls the screen into the
            // scrollback first.
            t.setCursorPos(1, 1);
            t.eraseDisplay(.below, false);
            return fill;
        }

        /// Puts back the state that the capture doesn't carry: what the
        /// output that arrived first set, or what `pane_state` applied
        /// before the capture's reply.
        fn end(self: Fill, t: *Terminal) void {
            const screen = self.screen;
            t.scrolling_region = self.region;
            t.modes.set(.origin, self.origin);
            screen.cursor.protected = self.protected;
            screen.protected_mode = self.protected_mode;
            screen.charset = self.charset;
            screen.cursor.style = self.style;
            screen.manualStyleUpdate() catch |err| {
                log.warn("restoring pane style after capture failed err={}", .{err});
                screen.cursor.style = .{};
                screen.manualStyleUpdate() catch unreachable;
            };
        }
    };

    fn receivedPaneHistory(
        self: *Viewer,
        screen_key: ScreenSet.Key,
        id: usize,
        content: []const u8,
    ) !void {
        // Get our pane
        const entry = self.panes.getEntry(id) orelse {
            log.info("received pane history for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr;
        const t: *Terminal = &pane.terminal;
        _ = try t.switchScreen(screen_key);
        const screen: *Screen = t.screens.active;

        const fill: Fill = .begin(t);
        defer fill.end(t);

        // The capture is the pane's complete history, so anything already
        // in the scrollback is output that arrived first and scrolled.
        t.eraseDisplay(.scrollback, false);

        // Get a VT stream from the terminal so we can send data as-is into
        // it. The last rows of the history land in the active area at
        // first.
        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice(content);

        // Move the rows with content into the scrollback, leaving the
        // active area empty for the visible contents that come next.
        try screen.scrollClear();
        t.setCursorPos(1, 1);

        // Our active area should be empty
        if (comptime std.debug.runtime_safety) {
            var discarding: std.Io.Writer.Discarding = .init(&.{});
            screen.dumpString(&discarding.writer, .{
                .tl = screen.pages.getTopLeft(.active),
                .unwrap = false,
            }) catch unreachable;
            assert(discarding.count == 0);
        }
    }

    fn receivedPaneVisible(
        self: *Viewer,
        screen_key: ScreenSet.Key,
        id: usize,
        content: []const u8,
    ) !void {
        // Get our pane
        const entry = self.panes.getEntry(id) orelse {
            log.info("received pane visible for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr;
        const t: *Terminal = &pane.terminal;
        _ = try t.switchScreen(screen_key);

        const fill: Fill = .begin(t);
        defer fill.end(t);

        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice(content);
    }

    /// One screen of a view's capture (see `capturePane`). The primary
    /// screen comes first and starts the pending restore.
    fn receivedFollowerCapture(
        self: *Viewer,
        cap: Command.CapturePane,
        content: []const u8,
    ) Allocator.Error!void {
        // Decoded in place, then shrunk so that it frees at its length.
        const copy = try self.alloc.dupe(u8, content);
        errdefer self.alloc.free(copy);
        const decoded = try self.alloc.realloc(copy, control.unescape(copy).len);

        switch (cap.screen_key) {
            .primary => {
                if (self.restore) |*v| v.deinit(self.alloc);
                self.restore = .{ .pane_id = cap.id, .primary = decoded };
            },
            .alternate => {
                const restore = if (self.restore) |*v| v else null;
                if (restore == null or restore.?.pane_id != cap.id) {
                    self.alloc.free(decoded);
                    return;
                }
                self.alloc.free(restore.?.alternate);
                restore.?.alternate = decoded;
            },
        }
    }

    /// The last reply of a view's capture: the pane's state. Sends the
    /// `pane_restore` action with whatever screens were captured.
    fn receivedFollowerState(
        self: *Viewer,
        arena_alloc: Allocator,
        actions: *std.ArrayList(Action),
        id: usize,
        content: []const u8,
    ) Allocator.Error!void {
        var restore: PendingRestore = if (self.restore) |v| restore: {
            self.restore = null;
            if (v.pane_id == id) break :restore v;
            var stale = v;
            stale.deinit(self.alloc);
            break :restore .{ .pane_id = id };
        } else .{ .pane_id = id };
        defer restore.deinit(self.alloc);

        const line = std.mem.trim(u8, content, " \r\n");
        var state = output.parseFormatStruct(
            Format.list_panes.Struct(),
            line,
            Format.list_panes.delim,
        ) catch {
            log.info("failed to parse pane state line: {s}", .{line});
            return;
        };
        if (state.pane_id != id) return;
        state.cursor_shape = try arena_alloc.dupe(u8, state.cursor_shape);
        state.cursor_colour = try arena_alloc.dupe(u8, state.cursor_colour);
        state.pane_tabs = try arena_alloc.dupe(u8, state.pane_tabs);

        try actions.append(arena_alloc, .{ .pane_restore = .{
            .pane_id = id,
            .primary = try arena_alloc.dupe(u8, restore.primary),
            .alternate = try arena_alloc.dupe(u8, restore.alternate),
            .state = state,
        } });
    }

    /// Write the bytes that make a fresh view of a pane look the way
    /// `restore` says: the primary screen's contents, the alternate
    /// screen's when the pane is on it, then the modes, the scroll region
    /// and the cursor.
    pub fn writePaneRestore(
        writer: *std.Io.Writer,
        restore: Action.PaneRestore,
    ) std.Io.Writer.Error!void {
        const state = restore.state;

        // Start from a cleared primary screen without a scroll region or
        // origin mode, so the contents land where tmux had them.
        try writer.writeAll("\x1b[?6l\x1b[r\x1b[H\x1b[2J");
        try writeScreen(writer, restore.primary);

        if (state.alternate_on) {
            // Entering the alternate screen saves the primary screen's
            // cursor, which the pane gets back when it leaves.
            try writeCursor(writer, state.alternate_saved_x, state.alternate_saved_y);
            try writer.writeAll("\x1b[?1049h\x1b[H\x1b[2J");
            try writeScreen(writer, restore.alternate);
        }

        try writeMode(writer, "?1", state.keypad_cursor_flag);
        try writer.writeAll(if (state.keypad_flag) "\x1b=" else "\x1b>");
        try writeMode(writer, "4", state.insert_flag);
        try writeMode(writer, "?7", state.wrap_flag);
        try writeMode(writer, "?1000", state.mouse_standard_flag);
        try writeMode(writer, "?1002", state.mouse_button_flag);
        try writeMode(writer, "?1003", state.mouse_all_flag);
        try writeMode(writer, "?1005", state.mouse_utf8_flag);
        try writeMode(writer, "?1006", state.mouse_sgr_flag);
        try writeMode(writer, "?1004", state.focus_flag);
        try writeMode(writer, "?2004", state.bracketed_paste);
        try writeMode(writer, "?12", state.cursor_blinking);
        try writeMode(writer, "?25", state.cursor_flag);
        if (cursorStyle(state.cursor_shape, state.cursor_blinking)) |style| {
            try writer.print("\x1b[{d} q", .{style});
        }

        // Setting the scroll region homes the cursor, and origin mode
        // makes the cursor position relative to the region, so the cursor
        // goes last.
        const region = state.scroll_region_upper < state.scroll_region_lower and
            state.scroll_region_lower < max_coord;
        if (region) try writer.print("\x1b[{d};{d}r", .{
            state.scroll_region_upper + 1,
            state.scroll_region_lower + 1,
        });
        try writeMode(writer, "?6", state.origin_flag);
        const top = if (region and state.origin_flag) state.scroll_region_upper else 0;
        try writeCursor(writer, state.cursor_x, state.cursor_y -| top);
    }

    /// tmux reports a position it doesn't have as UINT_MAX. Anything past
    /// what a terminal can be is skipped.
    const max_coord = std.math.maxInt(u16);

    /// `capture-pane` gives lines rather than a stream, so they are
    /// re-terminated for a terminal.
    fn writeScreen(writer: *std.Io.Writer, content: []const u8) std.Io.Writer.Error!void {
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, content, "\r\n"), '\n');
        var first = true;
        while (it.next()) |line| {
            if (!first) try writer.writeAll("\r\n");
            first = false;
            try writer.writeAll(std.mem.trimEnd(u8, line, "\r"));
        }

        // With -e, tmux doesn't reset the style after the last line when
        // its last cell is styled. The program in the pane didn't set it,
        // so it mustn't color what the program draws next.
        try writer.writeAll("\x1b[0m");
    }

    fn writeCursor(writer: *std.Io.Writer, x: usize, y: usize) std.Io.Writer.Error!void {
        if (x >= max_coord or y >= max_coord) return;
        try writer.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
    }

    fn writeMode(writer: *std.Io.Writer, comptime mode: []const u8, on: bool) std.Io.Writer.Error!void {
        try writer.writeAll("\x1b[" ++ mode);
        try writer.writeByte(if (on) 'h' else 'l');
    }

    /// The DECSCUSR style for a tmux cursor shape, if it isn't the default.
    fn cursorStyle(shape: []const u8, blinking: bool) ?u8 {
        const steady: u8 = if (std.mem.eql(u8, shape, "block"))
            2
        else if (std.mem.eql(u8, shape, "underline"))
            4
        else if (std.mem.eql(u8, shape, "bar"))
            6
        else
            return null;
        return if (blinking) steady - 1 else steady;
    }

    fn receivedOutput(
        self: *Viewer,
        id: usize,
        data: []const u8,
    ) !void {
        if (!self.mirror_panes) return;
        const entry = self.panes.getEntry(id) orelse {
            log.info("received output for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr;
        const stream = try pane.outputStream(self.alloc);

        // The parser leaves `%output` escaped; see control.unescape.
        var stack_buf: [4096]u8 = undefined;
        var stack: std.heap.BufferFirstAllocator = .init(&stack_buf, self.alloc);
        const alloc = stack.allocator();
        const copy = try alloc.dupe(u8, data);
        defer alloc.free(copy);
        stream.nextSlice(control.unescape(copy));
    }

    /// Walk `layout` and make sure every pane in it has an entry in
    /// `panes_new`.
    ///
    /// Panes that already exist in `panes_old` are copied over as is.
    /// New panes get a fresh terminal sized to match the layout.
    ///
    /// The layout comes from the control mode stream, which any program
    /// running in the terminal can write to. Returns `error.InvalidLayout`
    /// if a new pane's size is zero or too large for a terminal. Callers
    /// treat any error as fatal and move the viewer to the defunct state.
    fn initLayout(
        io: std.Io,
        gpa_alloc: Allocator,
        panes_old: *const PanesMap,
        panes_new_: ?*PanesMap,
        layout: Layout,
    ) !void {
        switch (layout.content) {
            // Nested layouts, continue going.
            .horizontal, .vertical => |layouts| {
                for (layouts) |l| {
                    try initLayout(
                        io,
                        gpa_alloc,
                        panes_old,
                        panes_new_,
                        l,
                    );
                }
            },

            // A leaf! Initialize.
            .pane => |id| pane: {
                // Without a map to fill, the leaves are only checked.
                const panes_new = panes_new_ orelse {
                    _ = try paneSize(layout);
                    break :pane;
                };
                const gop = try panes_new.getOrPut(gpa_alloc, id);
                if (gop.found_existing) break :pane;
                errdefer _ = panes_new.swapRemove(gop.key_ptr.*);

                // If we already have this pane, it is already initialized
                // so just copy it over.
                if (panes_old.getEntry(id)) |entry| {
                    gop.value_ptr.* = entry.value_ptr.*;
                    break :pane;
                }

                const grid = try paneSize(layout);
                var t: Terminal = try .init(io, gpa_alloc, .{
                    .cols = grid.cols,
                    .rows = grid.rows,
                });
                errdefer t.deinit(gpa_alloc);

                gop.value_ptr.* = .{
                    .terminal = t,
                };
            },
        }
    }

    /// The size of a layout leaf as a terminal size. The size comes from
    /// untrusted input, so it has to fit in a terminal and not be empty.
    fn paneSize(layout: Layout) error{InvalidLayout}!struct {
        cols: size.CellCountInt,
        rows: size.CellCountInt,
    } {
        const cols = std.math.cast(
            size.CellCountInt,
            layout.width,
        ) orelse return error.InvalidLayout;
        const rows = std.math.cast(
            size.CellCountInt,
            layout.height,
        ) orelse return error.InvalidLayout;
        if (cols == 0 or rows == 0) return error.InvalidLayout;
        return .{ .cols = cols, .rows = rows };
    }

    /// Enters the command queue state from any other state, queueing
    /// the commands and returning an action to execute the first command.
    fn enterCommandQueue(
        self: *Viewer,
        arena_alloc: Allocator,
        commands: []const Command,
    ) Allocator.Error![]const Action {
        assert(self.state != .command_queue);
        assert(commands.len > 0);

        // Build our command string to send for the action.
        var builder: std.Io.Writer.Allocating = .init(arena_alloc);
        commands[0].formatCommand(&builder.writer) catch return error.OutOfMemory;
        const action: Action = .{ .command = builder.writer.buffered() };

        // Add our commands
        try self.command_queue.ensureUnusedCapacity(self.alloc, commands.len);
        for (commands) |cmd| self.command_queue.appendAssumeCapacity(cmd);

        // Move into the command queue state
        self.state = .command_queue;

        return self.singleAction(action);
    }

    /// Queue multiple commands to execute. This doesn't add anything
    /// to the actions queue or return actions or anything because the
    /// command_queue state will automatically send the next command when
    /// it receives output.
    fn queueCommands(
        self: *Viewer,
        commands: []const Command,
    ) Allocator.Error!void {
        try self.command_queue.ensureUnusedCapacity(
            self.alloc,
            commands.len,
        );
        for (commands) |command| {
            self.command_queue.appendAssumeCapacity(command);
        }
    }

    /// Queue a `list-windows`, unless one is already waiting to be sent:
    /// tmux runs that one after whatever made us ask, so its reply covers
    /// it. One that is in flight (the head of the queue) may have run
    /// before, so it doesn't count.
    fn queueListWindows(self: *Viewer) Allocator.Error!void {
        var it = self.command_queue.iterator(.forward);
        _ = it.next();
        while (it.next()) |command| {
            if (command.* == .list_windows) return;
        }
        try self.queueCommands(&.{.list_windows});
    }

    /// Helper to return a single action. The input action may use the arena
    /// for allocated memory; this will not touch the arena.
    fn singleAction(self: *Viewer, action: Action) []const Action {
        // Make our single action slice.
        self.action_single[0] = action;
        return &self.action_single;
    }

    fn defunct(self: *Viewer) []const Action {
        self.state = .defunct;
        return self.singleAction(.exit);
    }
};

const State = enum {
    /// We start in this state just after receiving the initial
    /// DCS 1000p opening sequence. We wait for an initial
    /// begin/end block that is guaranteed to be sent by tmux for
    /// the initial control mode command. (See tmux server-client.c
    /// where control mode starts).
    startup_block,

    /// After receiving the initial block, we wait for a session-changed
    /// notification to record the initial session ID.
    startup_session,

    /// Tmux has closed the control mode connection
    defunct,

    /// We're sitting on the command queue waiting for command output
    /// in the order provided in the `command_queue` field. This field
    /// isn't part of the state because it can be queued at any state.
    ///
    /// Precondition: if self.command_queue.len > 0, then the first
    /// command in the queue has already been sent to tmux (via a
    /// `command` Action). The next output is assumed to be the result
    /// of this command.
    ///
    /// To satisfy the above, any transitions INTO this state should
    /// send a command Action for the first command in the queue.
    command_queue,
};

const Command = union(enum) {
    /// List all windows so we can sync our window state.
    list_windows,

    /// Capture history for the given pane ID.
    pane_history: CapturePane,

    /// Capture visible area for the given pane ID.
    pane_visible: CapturePane,

    /// Capture the pane terminal state as best we can. The pane ID(s)
    /// are part of the output so we can map it back to our panes.
    pane_state,

    /// Get the tmux server version.
    tmux_version,

    /// User command. This is a command provided by the user. Since
    /// this is user provided, we can't be sure what it is.
    user: User,

    /// A command that was already in flight when the session changed.
    /// Its reply is about the old session and is dropped. This is never
    /// sent: it only ever takes the place of a command that was.
    stale,

    /// Capture the visible contents of one screen of a pane so that a
    /// newly created view of it isn't blank. The pane ID is carried here
    /// because the output doesn't identify itself.
    follower_capture: CapturePane,

    /// The modes, cursor and scroll region of the pane whose screens were
    /// just captured, so the view resumes where tmux left off.
    follower_state: usize,

    const CapturePane = struct {
        id: usize,
        screen_key: ScreenSet.Key,
    };

    /// A command line from outside the viewer, followed by a command of
    /// our own that marks the end of its output. tmux runs each line on
    /// its own and in order, so the marker's block always comes after
    /// every block of the user's line, even if that line failed.
    const User = struct {
        /// The user's line and the marker line, ready to send. Owned by
        /// the viewer allocator.
        line: []const u8,

        /// Makes the marker unique, so output that merely looks like a
        /// marker can't end the wrong command.
        id: u32,

        /// The marker command, to be formatted with the id. It prints the
        /// marker text and has no other effect.
        const marker_command = "display-message -p '" ++ marker_text ++ "'\n";
        const marker_text = "ghostty-command-end {d}";

        /// True if `data` is the output of this command's end marker.
        fn isEnd(self: User, data: []const u8) bool {
            var buf: [64]u8 = undefined;
            const marker = std.fmt.bufPrint(
                &buf,
                marker_text,
                .{self.id},
            ) catch unreachable;
            return std.mem.eql(u8, std.mem.trim(u8, data, " \r\n"), marker);
        }
    };

    pub fn deinit(self: Command, alloc: Allocator) void {
        return switch (self) {
            .list_windows,
            .pane_history,
            .pane_visible,
            .pane_state,
            .tmux_version,
            .follower_capture,
            .follower_state,
            .stale,
            => {},
            .user => |v| alloc.free(v.line),
        };
    }

    /// Format the command into the command that should be executed
    /// by tmux. Trailing newlines are appended so this can be sent as-is
    /// to tmux.
    pub fn formatCommand(
        self: Command,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .list_windows => try writer.writeAll(std.fmt.comptimePrint(
                "list-windows -F '{s}'\n",
                .{comptime Format.list_windows.comptimeFormat()},
            )),

            .pane_history => |cap| try writer.print(
                // -p = output to stdout instead of buffer
                // -e = output escape sequences for SGR
                // -C = escape non-printables, so that the escape
                //   sequences -e emits can't terminate the DCS that
                //   carries the control stream. control.unescape undoes
                //   this.
                // -a = capture alternate screen (only valid for alternate)
                // -q = quiet, don't error if alternate screen doesn't exist
                // -S - = start at the top of history ("-")
                // -E -1 = end at the last line of history (1 before the
                //   visible area is -1).
                // -t %{d} = target a specific pane ID
                "capture-pane -p -e -C -q {s}-S - -E -1 -t %{d}\n",
                .{
                    if (cap.screen_key == .alternate) "-a " else "",
                    cap.id,
                },
            ),

            .pane_visible => |cap| try writer.print(
                // -p = output to stdout instead of buffer
                // -e = output escape sequences for SGR
                // -C = escape non-printables; see pane_history
                // -a = capture alternate screen (only valid for alternate)
                // -q = quiet, don't error if alternate screen doesn't exist
                // -t %{d} = target a specific pane ID
                // (no -S/-E = capture visible area only)
                "capture-pane -p -e -C -q {s}-t %{d}\n",
                .{
                    if (cap.screen_key == .alternate) "-a " else "",
                    cap.id,
                },
            ),

            // -s = every pane of the session, not just the current window
            .pane_state => try writer.writeAll(std.fmt.comptimePrint(
                "list-panes -s -F '{s}'\n",
                .{comptime Format.list_panes.comptimeFormat()},
            )),

            .tmux_version => try writer.writeAll(std.fmt.comptimePrint(
                "display-message -p '{s}'\n",
                .{comptime Format.tmux_version.comptimeFormat()},
            )),

            .user => |v| try writer.writeAll(v.line),

            .stale => unreachable,

            .follower_capture => |cap| try writer.print(
                // -C so that the escape sequences -e emits can't
                // terminate the DCS; see pane_history. -J so that lines
                // tmux wrapped come back whole: the view wraps them again
                // and, like tmux, reflows them when the pane is resized
                // later, which rows broken at the width of the capture
                // can't do. -q so that a pane without an alternate screen
                // answers with nothing.
                "capture-pane -p -e -C -J -q{s} -t %{d}\n",
                .{ if (cap.screen_key == .alternate) " -a" else "", cap.id },
            ),

            .follower_state => |id| {
                try writer.print("display-message -p -t %{d} -F '", .{id});
                try writer.writeAll(comptime Format.list_panes.comptimeFormat());
                try writer.writeAll("'\n");
            },
        }
    }
};

/// Format strings used for commands in our viewer.
const Format = struct {
    /// The variables included in this format, in order.
    vars: []const output.Variable,

    /// The delimiter to use between variables. This must be a character
    /// guaranteed to not appear in any of the variable outputs.
    delim: u8,

    const list_panes: Format = .{
        .delim = ';',
        .vars = &.{
            .pane_id,
            // Cursor position & appearance
            .cursor_x,
            .cursor_y,
            .cursor_flag,
            .cursor_shape,
            .cursor_colour,
            .cursor_blinking,
            // Alternate screen
            .alternate_on,
            .alternate_saved_x,
            .alternate_saved_y,
            // Terminal modes
            .insert_flag,
            .wrap_flag,
            .keypad_flag,
            .keypad_cursor_flag,
            .origin_flag,
            // Mouse modes
            .mouse_all_flag,
            .mouse_button_flag,
            .mouse_standard_flag,
            .mouse_utf8_flag,
            .mouse_sgr_flag,
            // Focus & special features
            .focus_flag,
            .bracketed_paste,
            // Scroll region
            .scroll_region_upper,
            .scroll_region_lower,
            // Tab stops
            .pane_tabs,
        },
    };

    /// Window names can contain any punctuation, so the name goes last
    /// and takes the rest of the line (see `parseFormatStructRest`).
    /// In a window's context `pane_id` is the window's active pane.
    const list_windows: Format = .{
        .delim = '\t',
        .vars = &.{
            .session_id,
            .window_id,
            .window_index,
            .window_active,
            .window_zoomed_flag,
            .pane_id,
            .window_width,
            .window_height,
            .window_layout,
            .window_visible_layout,
            .affinities,
            .window_name,
        },
    };

    const tmux_version: Format = .{
        .delim = ' ',
        .vars = &.{.version},
    };

    /// The format string, available at comptime.
    pub fn comptimeFormat(comptime self: Format) []const u8 {
        return output.comptimeFormat(self.vars, self.delim);
    }

    /// The struct that can contain the parsed output.
    pub fn Struct(comptime self: Format) type {
        return output.FormatStruct(self.vars);
    }
};

const TestStep = struct {
    input: Viewer.Input,
    contains_tags: []const std.meta.Tag(Viewer.Action) = &.{},
    contains_command: []const u8 = "",
    check: ?*const fn (viewer: *Viewer, []const Viewer.Action) anyerror!void = null,
    check_command: ?*const fn (viewer: *Viewer, []const u8) anyerror!void = null,

    fn run(self: TestStep, viewer: *Viewer) !void {
        const actions = viewer.next(self.input);

        // Common mistake, forgetting the newline on a command.
        for (actions) |action| {
            if (action == .command) {
                try testing.expect(std.mem.endsWith(u8, action.command, "\n"));
            }
        }

        for (self.contains_tags) |tag| {
            var found = false;
            for (actions) |action| {
                if (action == tag) {
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }

        if (self.contains_command.len > 0) {
            var found = false;
            for (actions) |action| {
                if (action == .command and
                    std.mem.startsWith(u8, action.command, self.contains_command))
                {
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }

        if (self.check) |check_fn| {
            try check_fn(viewer, actions);
        }

        if (self.check_command) |check_fn| {
            var found = false;
            for (actions) |action| {
                if (action == .command) {
                    found = true;
                    try check_fn(viewer, action.command);
                }
            }
            try testing.expect(found);
        }
    }
};

/// A helper to run a series of test steps against a viewer and assert
/// that the expected actions are produced.
///
/// I'm generally not a fan of these types of abstracted tests because
/// it makes diagnosing failures harder, but being able to construct
/// simulated tmux inputs and verify outputs is going to be extremely
/// important since the tmux control mode protocol is very complex and
/// fragile.
fn testViewer(viewer: *Viewer, steps: []const TestStep) !void {
    for (steps, 0..) |step, i| {
        step.run(viewer) catch |err| {
            log.warn("testViewer step failed i={} step={}", .{ i, step });
            return err;
        };
    }
}

test "immediate exit" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
        .{
            .input = .{ .tmux = .exit },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
    });
}

test "session changed resets state" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "first",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = .{ .data = "3.5a" } } },
            .contains_command = "list-windows",
        },
        // Receive window layout with two panes (same format as "initial flow" test)
        .{
            .input = .{ .tmux = .{
                .block_end = .{ .data = "$1\t@0\t0\t1\t0\t%0\t83\t44\t027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]\t027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]\tA\tshell" },
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.session_id);
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expectEqualStrings("3.5a", v.tmux_version);

                    for (actions) |action| switch (action) {
                        .windows => |windows| {
                            // The action must reference viewer-owned state,
                            // not the temporary list used while parsing.
                            try testing.expectEqual(v.windows.items.ptr, windows.ptr);
                            try testing.expectEqual(v.windows.items.len, windows.len);
                            try testing.expectEqual(@as(usize, 0), windows[0].id);
                            return;
                        },
                        else => {},
                    };
                    return error.TestExpectedWindowsAction;
                }
            }).check,
        },
        // Now session changes - should reset everything but keep version.
        // A capture for the old session is still in flight, so the new
        // list-windows has to wait for its reply.
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 2,
                .name = "second",
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    for (actions) |action| try testing.expect(action != .command);
                    // Session ID should be updated
                    try testing.expectEqual(2, v.session_id);
                    // Windows should be cleared (empty windows action sent)
                    var found_empty_windows = false;
                    for (actions) |action| {
                        if (action == .windows and action.windows.len == 0) {
                            found_empty_windows = true;
                        }
                    }
                    try testing.expect(found_empty_windows);
                    // Old windows should be cleared
                    try testing.expectEqual(0, v.windows.items.len);
                    // Old panes should be cleared
                    try testing.expectEqual(0, v.panes.count());
                    // Version should still be preserved
                    try testing.expectEqualStrings("3.5a", v.tmux_version);
                }
            }).check,
        },
        // The old capture's reply is dropped and list-windows goes out.
        .{
            .input = .{ .tmux = .{ .block_end = .{ .data = "old session history" } } },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, v.panes.count());
                    try testing.expectEqual(1, v.command_queue.len());
                }
            }).check,
        },
        // Receive new window layout for new session (same layout, different session/window)
        // Uses same pane IDs 0,1 - they should be re-created since old panes were cleared
        .{
            .input = .{ .tmux = .{
                .block_end = .{ .data = "$2\t@1\t1\t1\t0\t%0\t83\t44\t027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]\t027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]\tA\tshell" },
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.session_id);
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(1, v.windows.items[0].id);
                    // Panes 0 and 1 should be created (fresh, since old ones were cleared)
                    try testing.expectEqual(2, v.panes.count());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "initial flow" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 42,
                .name = "main",
            } } },
            .contains_command = "display-message",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(42, v.session_id);
                }
            }).check,
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = .{ .data = "3.5a" } } },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqualStrings("3.5a", v.tmux_version);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{
                .block_end = .{ .data = "$0\t@0\t0\t1\t0\t%0\t83\t44\t027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]\t027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]\tA\tshell" },
            } },
            .contains_tags = &.{ .windows, .command },
            .contains_command = "capture-pane",
            // pane_history for pane 0 (primary)
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{
                .block_end = .{ .data =
                \\Hello, world!
                },
            } },
            // Moves on to pane_visible for pane 0 (primary)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("Hello, world!", str);
                    }
                    // Only the history's one row, with no blank rows after.
                    try testing.expectEqual(1, screen.pages.total_rows - pane.terminal.rows);
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("", str);
                    }
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = .{ .data = "" } } },
            // Moves on to pane_history for pane 0 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = .{ .data = "" } } },
            // Moves on to pane_visible for pane 0 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = .{ .data = "" } } },
            // Moves on to pane_history for pane 1 (primary)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = .{ .data = "" } } },
            // Moves on to pane_visible for pane 1 (primary)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = .{ .data = "" } } },
            // Moves on to pane_history for pane 1 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = .{ .data = "" } } },
            // Moves on to pane_visible for pane 1 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = .{ .data = "" } } },
        },
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "new output" } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    try testing.expect(std.mem.containsAtLeast(u8, str, 1, "new output"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 999, .data = "ignored" } } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "pane history after output that arrived first" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 42,
                .name = "main",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = .{ .data = "3.5a" } } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end = .{ .data = "$0\t@0\t0\t1\t0\t%0\t83\t44\t027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]\t027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]\tA\tshell" },
            } },
            .contains_tags = &.{ .windows, .command },
            .contains_command = "capture-pane",
        },
        // Before the reply to the history capture arrives, output scrolls
        // past the 20 rows of the pane and protects a row. Then a
        // full-screen program sets a scroll region and origin mode, draws,
        // parks the cursor near the top and leaves a background color and
        // the line drawing charset set.
        .{
            .input = .{ .tmux = .{ .output = .{
                .pane_id = 0,
                .data = "1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7\r\n8\r\n9\r\n10\r\n" ++
                    "11\r\n12\r\n13\r\n14\r\n15\r\n16\r\n17\r\n18\r\n19\r\n20\r\n" ++
                    "21\r\n22\r\n23\r\n24\r\n25" ++
                    "\x1b[18;1H\x1bVkept\x1bW" ++
                    "\x1b[5;10r\x1b[?6h" ++
                    "\x1b[Hone\r\ntwo\r\nthree\r\nfour\x1b[2;1H" ++
                    "\x1b[44m\x1b(0",
            } } },
        },
        // The history is one line: exactly that ends up in the scrollback.
        .{
            .input = .{ .tmux = .{ .block_end = .{ .data = "old line" } } },
            .contains_command = "capture-pane",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("old line", str);
                    }
                    try testing.expectEqual(1, screen.pages.total_rows - pane.terminal.rows);
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("", str);
                    }
                    try expectFillRestored(&pane.terminal);
                }
            }).check,
        },
        // The visible contents start at the top-left, and their style
        // isn't left behind.
        .{
            .input = .{ .tmux = .{ .block_end = .{ .data = "\x1b[31mtop\r\nnext" } } },
            .contains_command = "capture-pane",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("top\nnext", str);
                    }
                    try testing.expectEqual(1, screen.pages.total_rows - pane.terminal.rows);
                    try expectFillRestored(&pane.terminal);
                }
            }).check,
        },
    });
}

/// After a capture, the state set by the output that arrived first in the
/// test above is back in place.
fn expectFillRestored(t: *Terminal) !void {
    const screen: *Screen = t.screens.active;
    try testing.expectEqual(4, t.scrolling_region.top);
    try testing.expectEqual(9, t.scrolling_region.bottom);
    try testing.expect(t.modes.get(.origin));
    try testing.expectEqual(Style.Color{ .palette = 4 }, screen.cursor.style.bg_color);
    try testing.expectEqual(Style.Color.none, screen.cursor.style.fg_color);
    try testing.expectEqual(ansi.ProtectedMode.iso, screen.protected_mode);
    try testing.expect(screen.charset.charsets.g0 == .dec_special);
}

test "layout change" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = .{ .data = "3.5a" } } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end = .{ .data = "$0\t@0\t0\t1\t0\t%0\t83\t44\tb7dd,83x44,0,0,0\tb7dd,83x44,0,0,0\tA\tshell" },
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(1, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                }
            }).check,
        },
        // Complete all capture-pane commands for pane 0 (primary and alternate)
        // plus pane_state
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        // Now send a layout_change that splits into two panes
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Should still have 1 window
                    try testing.expectEqual(1, v.windows.items.len);
                    // Should now have 2 panes (0 and 2)
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                    try testing.expect(v.panes.contains(2));
                    // Commands should be queued for the new pane (4 capture-pane + 1 pane_state)
                    try testing.expectEqual(5, v.command_queue.len());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "layout change with zero width pane becomes defunct" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = .{ .data = "3.5a" } } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end = .{ .data = "$0\t@0\t0\t1\t0\t%0\t83\t44\tb7dd,83x44,0,0,0\tb7dd,83x44,0,0,0\tA\tshell" },
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(1, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                }
            }).check,
        },
        // Complete all capture-pane commands for pane 0 (primary and alternate)
        // plus pane_state
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        // Send a layout_change with a valid checksum but a zero-width pane.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "52aa,83x44,0,0[83x22,0,0,0,0x21,0,23,2]",
                .visible_layout = "52aa,83x44,0,0[83x22,0,0,0,0x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{.exit},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(.defunct, v.state);
                    try testing.expect(!v.panes.contains(2));
                }
            }).check,
        },
    });
}

test "layout change with oversized pane becomes defunct" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = .{ .data = "3.5a" } } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end = .{ .data = "$0\t@0\t0\t1\t0\t%0\t83\t44\tb7dd,83x44,0,0,0\tb7dd,83x44,0,0,0\tA\tshell" },
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(1, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                }
            }).check,
        },
        // Complete all capture-pane commands for pane 0 (primary and alternate)
        // plus pane_state
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        // Send a layout_change with a valid checksum but a pane wider than
        // our max column count.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "3afd,83x44,0,0[83x22,0,0,0,70000x21,0,23,2]",
                .visible_layout = "3afd,83x44,0,0[83x22,0,0,0,70000x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{.exit},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(.defunct, v.state);
                    try testing.expect(!v.panes.contains(2));
                }
            }).check,
        },
    });
}

test "layout_change does not return command when queue not empty" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = .{ .data = "3.5a" } } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end = .{ .data = "$0\t@0\t0\t1\t0\t%0\t83\t44\tb7dd,83x44,0,0,0\tb7dd,83x44,0,0,0\tA\tshell" },
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        // Do NOT complete capture-pane commands - queue still has commands.
        // Send a layout_change that splits into two panes.
        // This should NOT return a command action since queue was not empty.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.panes.count());
                    // Should not contain a command action
                    for (actions) |action| {
                        try testing.expect(action != .command);
                    }
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "layout_change returns command when queue was empty" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = .{ .data = "3.5a" } } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end = .{ .data = "$0\t@0\t0\t1\t0\t%0\t83\t44\tb7dd,83x44,0,0,0\tb7dd,83x44,0,0,0\tA\tshell" },
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete all capture-pane commands for pane 0
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = .{ .block_end = .{ .data = "" } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Now send a layout_change that splits into two panes.
        // This should return a command action since we're queuing commands
        // for the new pane and the queue was empty.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "window_add queues list_windows when queue empty" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = .{ .data = "3.5a" } } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end = .{ .data = "$0\t@0\t0\t1\t0\t%0\t83\t44\tb7dd,83x44,0,0,0\tb7dd,83x44,0,0,0\tA\tshell" },
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete all capture-pane commands for pane 0
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = .{ .block_end = .{ .data = "" } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Now send window_add - should trigger list-windows command
        .{
            .input = .{ .tmux = .{ .window_add = .{ .id = 1 } } },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Command queue should have list_windows
                    try testing.expect(!v.command_queue.empty());
                    try testing.expectEqual(1, v.command_queue.len());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "window_add queues list_windows when queue not empty" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = .{ .data = "3.5a" } } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end = .{ .data = "$0\t@0\t0\t1\t0\t%0\t83\t44\tb7dd,83x44,0,0,0\tb7dd,83x44,0,0,0\tA\tshell" },
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Queue should have capture-pane commands
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        // Do NOT complete capture-pane commands - queue still has commands.
        // Send window_add - should queue list-windows but NOT return command action
        .{
            .input = .{ .tmux = .{ .window_add = .{ .id = 1 } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Should not contain a command action since queue was not empty
                    for (actions) |action| {
                        try testing.expect(action != .command);
                    }
                    // But list_windows should be in the queue
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "two pane flow with pane state" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial block_end from attach
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        // Session changed notification
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "0",
            } } },
            .contains_command = "display-message",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, v.session_id);
                }
            }).check,
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = .{ .data = "3.5a" } } },
            .contains_command = "list-windows",
        },
        // list-windows output with 2 panes in a vertical split
        .{
            .input = .{ .tmux = .{
                .block_end = .{ .data = "$0\t@0\t0\t1\t0\t%0\t165\t79\tca97,165x79,0,0[165x40,0,0,0,165x38,0,41,4]\tca97,165x79,0,0[165x40,0,0,0,165x38,0,41,4]\tA\tshell" },
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items.len);
                    const window = v.windows.items[0];
                    try testing.expectEqual(0, window.id);
                    try testing.expectEqual(165, window.width);
                    try testing.expectEqual(79, window.height);
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                    try testing.expect(v.panes.contains(4));
                }
            }).check,
        },
        // capture-pane pane 0 primary history
        .{
            .input = .{ .tmux = .{
                .block_end = .{ .data =
                \\prompt %
                \\prompt %
                },
            } },
        },
        // capture-pane pane 0 primary visible
        .{
            .input = .{ .tmux = .{
                .block_end = .{ .data =
                \\prompt %
                },
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        // History has 2 lines with "prompt %" (padded to screen width)
                        try testing.expect(std.mem.containsAtLeast(u8, str, 2, "prompt %"));
                    }
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("prompt %", str);
                    }
                }
            }).check,
        },
        // capture-pane pane 0 alternate history (empty)
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        // capture-pane pane 0 alternate visible (empty)
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        // capture-pane pane 4 primary history
        .{
            .input = .{ .tmux = .{
                .block_end = .{ .data =
                \\prompt %
                },
            } },
        },
        // capture-pane pane 4 primary visible
        .{
            .input = .{ .tmux = .{
                .block_end = .{ .data =
                \\prompt %
                },
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(4).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("prompt %", str);
                    }
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        // Active screen starts with "prompt %" at beginning
                        try testing.expect(std.mem.startsWith(u8, str, "prompt %"));
                    }
                }
            }).check,
        },
        // capture-pane pane 4 alternate history (empty)
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        // capture-pane pane 4 alternate visible (empty)
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        // list-panes output with terminal state
        .{
            .input = .{ .tmux = .{
                .block_end = .{ .data =
                \\%0;42;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;1;0;0;1;;;0;39;8,16,24,32,40,48,56,64,72,80,88,96,104,112,120,128,136,144,152,160
                \\%4;10;5;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;;;0;37;8,16,24,32,40,48,56,64,72,80,88,96,104,112,120,128,136,144,152,160
                },
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Pane 0: cursor at (42, 0), cursor visible, wraparound on
                    {
                        const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                        const t: *Terminal = &pane.terminal;
                        const screen: *Screen = t.screens.get(.primary).?;
                        try testing.expectEqual(42, screen.cursor.x);
                        try testing.expectEqual(0, screen.cursor.y);
                        try testing.expect(t.modes.get(.cursor_visible));
                        try testing.expect(t.modes.get(.wraparound));
                        try testing.expect(!t.modes.get(.insert));
                        try testing.expect(!t.modes.get(.origin));
                        try testing.expect(!t.modes.get(.keypad_keys));
                        try testing.expect(!t.modes.get(.cursor_keys));
                        try testing.expect(t.modes.get(.mouse_event_button));
                        try testing.expect(!t.modes.get(.mouse_event_normal));
                        try testing.expect(t.modes.get(.mouse_format_sgr));
                    }
                    // Pane 4: cursor at (10, 5), cursor visible, wraparound on
                    {
                        const pane: *Viewer.Pane = v.panes.getEntry(4).?.value_ptr;
                        const t: *Terminal = &pane.terminal;
                        const screen: *Screen = t.screens.get(.primary).?;
                        try testing.expectEqual(10, screen.cursor.x);
                        try testing.expectEqual(5, screen.cursor.y);
                        try testing.expect(t.modes.get(.cursor_visible));
                        try testing.expect(t.modes.get(.wraparound));
                        try testing.expect(!t.modes.get(.insert));
                        try testing.expect(!t.modes.get(.origin));
                        try testing.expect(!t.modes.get(.keypad_keys));
                        try testing.expect(!t.modes.get(.cursor_keys));
                    }
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .exit },
            .contains_tags = &.{.exit},
        },
    });
}

test "tmux output state unsplit CSI" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    var terminal: Terminal = try .init(testing.io, testing.allocator, .{
        .cols = 80,
        .rows = 24,
    });

    viewer.panes.put(testing.allocator, 42, .{
        .terminal = terminal,
    }) catch |err| {
        terminal.deinit(testing.allocator);
        return err;
    };

    try viewer.receivedOutput(42, "\x1b[32mX");

    const entry = viewer.panes.getEntry(42) orelse return error.ExpectedPane42;
    const screen = entry.value_ptr.terminal.screens.active;
    const text = try screen.dumpStringAlloc(testing.allocator, .{ .active = .{} });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("X", text);
}

test "tmux output state split CSI" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    var terminal: Terminal = try .init(testing.io, testing.allocator, .{
        .cols = 80,
        .rows = 24,
    });

    viewer.panes.put(testing.allocator, 42, .{
        .terminal = terminal,
    }) catch |err| {
        terminal.deinit(testing.allocator);
        return err;
    };

    try viewer.receivedOutput(42, "\x1b[32");
    try viewer.receivedOutput(42, "mX");

    const entry = viewer.panes.getEntry(42) orelse return error.ExpectedPane42;
    const screen = entry.value_ptr.terminal.screens.active;
    const text = try screen.dumpStringAlloc(testing.allocator, .{ .active = .{} });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("X", text);
}

test "pane state ignores out of bounds scroll region" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "0",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = .{ .data = "3.5a" } } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end = .{ .data = "$0\t@0\t0\t1\t0\t%0\t80\t24\tb25d,80x24,0,0,0\tb25d,80x24,0,0,0\tA\tshell" },
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // capture-pane primary/alternate history/visible
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        .{ .input = .{ .tmux = .{ .block_end = .{ .data = "" } } } },
        // list-panes with a scroll region bottom far past the screen
        .{
            .input = .{ .tmux = .{
                .block_end = .{ .data = "%0;0;5;1;;;0;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;0;0;60000;" },
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const t: *Terminal = &pane.terminal;
                    // Verify the line parsed and was applied.
                    try testing.expectEqual(5, t.screens.active.cursor.y);
                    try testing.expectEqual(0, t.scrolling_region.top);
                    try testing.expectEqual(t.rows - 1, t.scrolling_region.bottom);
                }
            }).check,
        },
        // Vertical tabs act as linefeeds and must scroll within the screen.
        .{
            .input = .{ .tmux = .{ .output = .{
                .pane_id = 0,
                .data = &@as([30]u8, @splat('\x0b')),
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const t: *Terminal = &pane.terminal;
                    try testing.expectEqual(t.rows - 1, t.screens.active.cursor.y);
                }
            }).check,
        },
    });
}

test "tmux raw startup selects primary screen" {
    try testRawStartupScreen(false);
}

test "tmux raw startup selects alternate screen" {
    try testRawStartupScreen(true);
}

fn testRawStartupScreen(comptime alternate_on: bool) !void {
    var parser: control.Parser = .{ .buffer = .init(testing.allocator) };

    defer parser.deinit();

    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    const input =
        // Initial connection.
        "%begin 1 1 0\n" ++
        "%end 1 1 0\n" ++
        "%session-changed $42 main\n" ++

        // Tmux version response.
        "%begin 2 2 1\n" ++
        "3.5a\n" ++
        "%end 2 2 1\n" ++

        // Window and pane layout.
        "%begin 3 3 1\n" ++
        "$42\t@0\t0\t1\t0\t%42\t80\t24\td962,80x24,0,0,42\td962,80x24,0,0,42\tA\tshell\n" ++
        "%end 3 3 1\n" ++

        // Output of a hook. tmux writes it to us but it is not the reply
        // to anything we sent, so it must not be taken as the history.
        "%begin 9 9 0\n" ++
        "HOOKED\n" ++
        "%end 9 9 0\n" ++

        // Primary screen history.
        "%begin 4 4 1\n" ++
        "%end 4 4 1\n" ++

        // Primary screen visible contents.
        "%begin 5 5 1\n" ++
        "%end 5 5 1\n" ++

        // Alternate screen history.
        "%begin 6 6 1\n" ++
        "%end 6 6 1\n" ++

        // Alternate screen visible contents.
        "%begin 7 7 1\n" ++
        "%end 7 7 1\n" ++

        // Cursor position and terminal modes.
        "%begin 8 8 1\n" ++
        "%42;0;0;1;block;default;0;" ++
        (if (alternate_on) "1;0;0;" else "0;0;0;") ++
        "0;1;0;0;0;" ++
        "0;0;0;0;0;" ++
        "0;0;0;23;8,16,24,32,40,48,56,64,72\n" ++
        "%end 8 8 1\n" ++

        // Live output after initialization.
        "%output %42 hello\n";

    const expected_commands = [_][]const u8{
        "display-message",
        "list-windows",
        "capture-pane -p -e -C -q -S - -E -1 -t %42\n",
        "capture-pane -p -e -C -q -t %42\n",
        "capture-pane -p -e -C -q -a -S - -E -1 -t %42\n",
        "capture-pane -p -e -C -q -a -t %42\n",
        "list-panes -s",
    };

    var command_index: usize = 0;

    for (input) |byte| {
        if (try parser.put(byte)) |notification| {
            const actions = viewer.next(.{ .tmux = notification });

            for (actions) |action| {
                switch (action) {
                    .command => |command| {
                        try testing.expect(command_index < expected_commands.len);
                        const expected = expected_commands[command_index];
                        try testing.expect(
                            std.mem.startsWith(
                                u8,
                                command,
                                expected,
                            ),
                        );
                        command_index += 1;
                    },
                    .windows,
                    .active_window,
                    .active_pane,
                    .window_renamed,
                    .pane_restore,
                    => {},
                    .exit => {
                        return error.UnexpectedViewerExit;
                    },
                }
            }
        }
    }
    try testing.expectEqual(expected_commands.len, command_index);
    try testing.expectEqual(@as(usize, 42), viewer.session_id);
    try testing.expectEqualStrings("3.5a", viewer.tmux_version);

    try testing.expectEqual(@as(usize, 1), viewer.windows.items.len);
    try testing.expectEqual(@as(usize, 1), viewer.panes.count());
    try testing.expect(viewer.panes.contains(42));
    try testing.expect(viewer.command_queue.empty());
    const entry = viewer.panes.getEntry(42) orelse
        return error.ExpectedPane42;

    const pane = entry.value_ptr;

    const expected_key: ScreenSet.Key =
        if (alternate_on) .alternate else .primary;

    try testing.expectEqual(
        expected_key,
        pane.terminal.screens.active_key,
    );

    const screen = pane.terminal.screens.active;

    const text = try screen.dumpStringAlloc(
        testing.allocator,
        .{ .active = .{} },
    );
    defer testing.allocator.free(text);

    try testing.expectEqualStrings("hello", text);

    const other_key: ScreenSet.Key =
        if (alternate_on) .primary else .alternate;

    const other_screen = pane.terminal.screens.get(other_key) orelse
        return error.ExpectedOtherScreen;

    const other_text = try other_screen.dumpStringAlloc(
        testing.allocator,
        .{ .active = .{} },
    );
    defer testing.allocator.free(other_text);

    try testing.expectEqualStrings("", other_text);
}

/// Bring a viewer to the steady state of a session with the given
/// `list-windows` reply, every pane captured and the queue empty.
fn testAttach(viewer: *Viewer, list_windows: []const u8) !void {
    try testViewer(viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = .{ .client = false } } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{ .id = 0, .name = "0" } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = .{ .data = "3.6" } } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{ .block_end = .{ .data = list_windows } } },
            .contains_tags = &.{.windows},
        },
    });

    // Four captures per pane, then the pane state.
    while (!viewer.command_queue.empty()) {
        _ = viewer.next(.{ .tmux = .{ .block_end = .{} } });
    }
    try testing.expect(viewer.state == .command_queue);
}

/// The output of the end marker that follows the `id`th user command.
fn testMarker(buf: []u8, id: u32) []const u8 {
    return std.fmt.bufPrint(buf, Command.User.marker_text, .{id}) catch unreachable;
}

fn testHasAction(actions: []const Viewer.Action, tag: std.meta.Tag(Viewer.Action)) bool {
    for (actions) |action| if (action == tag) return true;
    return false;
}

fn testCommand(actions: []const Viewer.Action) ?[]const u8 {
    for (actions) |action| if (action == .command) return action.command;
    return null;
}

test "list-windows carries window metadata" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    // Real tmux output: window @1 is zoomed on %2, the name contains a
    // space and a semicolon, and @2 has a name containing the delimiter.
    try testAttach(&viewer, "$0\t@0\t0\t0\t0\t%0\t80\t24\tb25d,80x24,0,0,0\tb25d,80x24,0,0,0\tA0,1\ta b;c\n" ++
        "$0\t@1\t1\t1\t1\t%2\t80\t24\t020a,80x24,0,0{40x24,0,0,1,39x24,41,0,2}\tb25f,80x24,0,0,2\tA0,1\teditor\n" ++
        "$0\t@2\t5\t0\t0\t%3\t80\t24\tb260,80x24,0,0,3\tb260,80x24,0,0,3\tA0,1\tx\ty ");

    try testing.expectEqual(3, viewer.windows.items.len);
    const w0 = viewer.windows.items[0];
    try testing.expectEqual(0, w0.index);
    try testing.expectEqualStrings("a b;c", w0.name);
    try testing.expect(!w0.active);
    try testing.expect(!w0.zoomed);
    try testing.expect(w0.visible_layout == null);
    try testing.expectEqual(0, w0.active_pane);
    try testing.expectEqualStrings("0,1", w0.affinities);

    const w1 = viewer.windows.items[1];
    try testing.expectEqual(1, w1.id);
    try testing.expect(w1.active);
    try testing.expect(w1.zoomed);
    try testing.expectEqual(2, w1.active_pane);
    try testing.expectEqual(2, w1.visible_layout.?.content.pane);
    // The full layout still has both panes, and both are tracked.
    try testing.expectEqual(2, w1.layout.content.horizontal.len);
    try testing.expect(viewer.panes.contains(1));
    try testing.expect(viewer.panes.contains(2));

    const w2 = viewer.windows.items[2];
    try testing.expectEqual(5, w2.index);
    try testing.expectEqualStrings("x\ty ", w2.name);
}

test "unusable list-windows reply keeps the windows" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();
    try testAttach(&viewer, "$0\t@0\t0\t1\t0\t%0\t80\t24\tb25d,80x24,0,0,0\tb25d,80x24,0,0,0\tA\tshell");

    // An error reply, then a reply we can't parse.
    for ([_]control.Notification{
        .{ .block_err = .{ .data = "no current session" } },
        .{ .block_end = .{ .data = "garbage" } },
        .{ .block_end = .{ .truncated = true } },
    }) |reply| {
        _ = viewer.next(.{ .tmux = .{ .window_add = .{ .id = 1 } } });
        const actions = viewer.next(.{ .tmux = reply });
        try testing.expect(!testHasAction(actions, .exit));
        try testing.expect(!testHasAction(actions, .windows));
        try testing.expectEqual(.command_queue, viewer.state);
        try testing.expectEqual(1, viewer.windows.items.len);
        try testing.expectEqualStrings("shell", viewer.windows.items[0].name);
        try testing.expect(viewer.command_queue.empty());
    }
}

test "pane restore writes contents, modes and cursor" {
    const state = try output.parseFormatStruct(
        Viewer.PaneState,
        "%3;4;5;1;bar;none;0;1;2;3;0;1;0;1;0;0;0;1;0;1;0;1;0;23;8,16",
        ';',
    );

    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try Viewer.writePaneRestore(&writer, .{
        .pane_id = 3,
        .primary = "a\nb\n",
        .alternate = "x\r\ny\n",
        .state = state,
    });
    try testing.expectEqualStrings(
        "\x1b[?6l\x1b[r\x1b[H\x1b[2J" ++ "a\r\nb\x1b[0m" ++
            // The primary cursor, saved by entering the alternate screen.
            "\x1b[4;3H" ++ "\x1b[?1049h\x1b[H\x1b[2J" ++ "x\r\ny\x1b[0m" ++
            "\x1b[?1h" ++ "\x1b>" ++ "\x1b[4l" ++ "\x1b[?7h" ++
            "\x1b[?1000h\x1b[?1002l\x1b[?1003l\x1b[?1005l\x1b[?1006h" ++
            "\x1b[?1004l\x1b[?2004h" ++ "\x1b[?12l\x1b[?25h" ++ "\x1b[6 q" ++
            "\x1b[1;24r" ++ "\x1b[?6l" ++ "\x1b[6;5H",
        writer.buffered(),
    );
}

test "pane restore doesn't leave the style of a capture set" {
    // capture-pane -e doesn't reset the style after the last line when
    // its last cell is styled. Neither what the program draws next nor the
    // primary cursor saved by entering the alternate screen may get it.
    const state = try output.parseFormatStruct(
        Viewer.PaneState,
        "%3;4;5;1;bar;none;0;1;2;3;0;1;0;1;0;0;0;1;0;1;0;1;0;23;8,16",
        ';',
    );

    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try Viewer.writePaneRestore(&writer, .{
        .pane_id = 3,
        .primary = "\x1b[43mprimary",
        .alternate = "\x1b[44malternate",
        .state = state,
    });

    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 20, .rows = 24 });
    defer t.deinit(testing.allocator);
    var stream = t.vtStream();
    defer stream.deinit();

    stream.nextSlice(writer.buffered());
    try testing.expect(t.screens.active.cursor.style.default());
    stream.nextSlice("\x1b[?1049l");
    try testing.expect(t.screens.active.cursor.style.default());
}

test "pane restore with origin mode places the cursor in the region" {
    // Primary screen, an unset saved cursor, origin mode inside rows 3-11.
    const state = try output.parseFormatStruct(
        Viewer.PaneState,
        "%1;0;5;1;default;none;0;0;4294967295;4294967295;0;1;0;0;1;0;0;0;0;0;0;0;2;10;",
        ';',
    );

    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try Viewer.writePaneRestore(&writer, .{
        .pane_id = 1,
        .primary = "",
        .alternate = "ignored",
        .state = state,
    });
    try testing.expect(std.mem.endsWith(
        u8,
        writer.buffered(),
        "\x1b[?25h" ++ "\x1b[3;11r" ++ "\x1b[?6h" ++ "\x1b[4;1H",
    ));
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "1049") == null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "ignored") == null);
}

test "pane restore gathers both screens and the state" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();
    try testAttach(&viewer, "$0\t@0\t0\t1\t0\t%0\t80\t24\tb25d,80x24,0,0,0\tb25d,80x24,0,0,0\tA\tshell");

    const first = viewer.capturePane(0);
    try testing.expect(std.mem.startsWith(u8, testCommand(first).?, "capture-pane -p -e -C -J -q -t %0"));
    {
        const actions = viewer.next(.{ .tmux = .{ .block_end = .{ .data = "one\\134two\ntwo\n" } } });
        try testing.expect(std.mem.startsWith(u8, testCommand(actions).?, "capture-pane -p -e -C -J -q -a -t %0"));
    }
    {
        const actions = viewer.next(.{ .tmux = .{ .block_end = .{ .data = "vim\n" } } });
        try testing.expect(std.mem.startsWith(u8, testCommand(actions).?, "display-message -p -t %0 -F '"));
    }
    const actions = viewer.next(.{ .tmux = .{ .block_end = .{
        .data = "%0;1;2;1;default;none;0;1;0;0;0;1;0;0;0;0;0;0;0;0;0;0;0;23;",
    } } });
    var found = false;
    for (actions) |action| switch (action) {
        .pane_restore => |v| {
            found = true;
            try testing.expectEqual(0, v.pane_id);
            try testing.expectEqualStrings("one\\two\ntwo\n", v.primary);
            try testing.expectEqualStrings("vim\n", v.alternate);
            try testing.expect(v.state.alternate_on);
            try testing.expectEqual(1, v.state.cursor_x);
            try testing.expectEqual(2, v.state.cursor_y);
        },
        else => {},
    };
    try testing.expect(found);
    try testing.expect(viewer.command_queue.empty());
}

test "error replies to captures and pane state are not content" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();
    try testAttach(&viewer, "$0\t@0\t0\t1\t0\t%0\t80\t24\tb25d,80x24,0,0,0\tb25d,80x24,0,0,0\tA\tshell");

    // The pane closed before the follower's capture ran: every reply is
    // an error and no restore goes out.
    const first = viewer.capturePane(7);
    try testing.expect(std.mem.startsWith(u8, testCommand(first).?, "capture-pane"));
    for (0..3) |_| {
        const actions = viewer.next(.{ .tmux = .{ .block_err = .{ .data = "can't find pane: %7" } } });
        try testing.expect(!testHasAction(actions, .pane_restore));
    }
    try testing.expect(viewer.command_queue.empty());

    // A capture too large to receive is dropped the same way, and a state
    // line we can't read sends nothing.
    _ = viewer.capturePane(0);
    _ = viewer.next(.{ .tmux = .{ .block_end = .{ .truncated = true } } });
    _ = viewer.next(.{ .tmux = .{ .block_end = .{ .data = "" } } });
    {
        const actions = viewer.next(.{ .tmux = .{ .block_end = .{ .data = "3,4" } } });
        try testing.expect(!testHasAction(actions, .pane_restore));
    }
    try testing.expect(viewer.command_queue.empty());

    // A pane state reply with a line we can't read skips that line.
    _ = viewer.next(.{ .tmux = .{ .layout_change = .{
        .window_id = 0,
        .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
        .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
        .raw_flags = "*",
    } } });
    for (0..4) |_| _ = viewer.next(.{ .tmux = .{ .block_end = .{} } });
    const actions = viewer.next(.{ .tmux = .{ .block_end = .{
        .data = "%2;3;1;1;;;0;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;0;0;20;\nnot a pane line",
    } } });
    try testing.expect(!testHasAction(actions, .exit));
    try testing.expectEqual(.command_queue, viewer.state);
    try testing.expectEqual(1, viewer.panes.getEntry(2).?.value_ptr.terminal.screens.active.cursor.y);
}

test "replies are matched to the right command with GUI and hook traffic" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();
    try testAttach(&viewer, "$0\t@0\t0\t1\t0\t%0\t80\t24\tb25d,80x24,0,0,0\tb25d,80x24,0,0,0\tA\tshell");

    var buf: [64]u8 = undefined;

    // tmux splits the window: the viewer starts capturing the new pane.
    {
        const actions = viewer.next(.{ .tmux = .{ .layout_change = .{
            .window_id = 0,
            .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
            .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
            .raw_flags = "*",
        } } });
        try testing.expect(std.mem.startsWith(u8, testCommand(actions).?, "capture-pane -p -e -C -q -S - -E -1 -t %2"));
    }

    // The GUI saves @affinities and the user runs a compound command from
    // the prompt while that capture is in flight. Both wait their turn.
    try testing.expectEqual(0, viewer.sendCommand("set @affinities \"0\"\n").len);
    try testing.expectEqual(0, viewer.sendCommand("display-message -p a ; display-message -p b\n").len);

    // A hook's output arrives first. It is no reply of ours.
    try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .block_end = .{
        .data = "HOOKED",
        .client = false,
    } } }).len);

    // The history reply lands in the right pane.
    _ = viewer.next(.{ .tmux = .{ .block_end = .{ .data = "pane two history" } } });
    {
        const screen = viewer.panes.getEntry(2).?.value_ptr.terminal.screens.active;
        const str = try screen.dumpStringAlloc(testing.allocator, .{ .history = .{} });
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("pane two history", str);
    }

    // The remaining captures and the pane state.
    for (0..3) |_| _ = viewer.next(.{ .tmux = .{ .block_end = .{} } });
    {
        const actions = viewer.next(.{ .tmux = .{ .block_end = .{
            .data = "%2;3;1;1;;;0;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;0;0;20;",
        } } });
        // Now the GUI's command goes out, followed by its end marker.
        const command = testCommand(actions).?;
        try testing.expect(std.mem.startsWith(u8, command, "set @affinities \"0\"\ndisplay-message -p '"));
        try testing.expect(std.mem.endsWith(u8, command, "'ghostty-command-end 0'\n"));
    }
    try testing.expectEqual(1, viewer.panes.getEntry(2).?.value_ptr.terminal.screens.active.cursor.y);

    // The reply to `set` alone doesn't finish it; its marker does.
    try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .block_end = .{} } }).len);
    {
        const actions = viewer.next(.{ .tmux = .{ .block_end = .{ .data = testMarker(&buf, 0) } } });
        try testing.expect(std.mem.startsWith(u8, testCommand(actions).?, "display-message -p a ; display-message -p b\n"));
    }

    // Two blocks for the compound command, one of them looking like a
    // marker for another command, then its marker.
    try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .block_end = .{ .data = "a" } } }).len);
    try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .block_err = .{ .data = testMarker(&buf, 0) } } }).len);
    try testing.expect(!viewer.command_queue.empty());
    _ = viewer.next(.{ .tmux = .{ .block_end = .{ .data = testMarker(&buf, 1) } } });
    try testing.expect(viewer.command_queue.empty());

    // A window refresh afterwards gets its own reply.
    _ = viewer.next(.{ .tmux = .{ .window_add = .{ .id = 1 } } });
    {
        const actions = viewer.next(.{ .tmux = .{ .block_end = .{
            .data = "$0\t@0\t0\t1\t0\t%0\t80\t24\te07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]\te07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]\tA0\tshell\n" ++
                "$0\t@1\t1\t0\t0\t%5\t80\t24\tb262,80x24,0,0,5\tb262,80x24,0,0,5\tA0\tnew",
        } } });
        try testing.expect(testHasAction(actions, .windows));
        try testing.expect(!testHasAction(actions, .exit));
    }
    try testing.expectEqual(2, viewer.windows.items.len);
}

test "session change waits for the user command in flight" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();
    try testAttach(&viewer, "$0\t@0\t0\t1\t0\t%0\t80\t24\tb25d,80x24,0,0,0\tb25d,80x24,0,0,0\tA\tshell");

    var buf: [64]u8 = undefined;
    try testing.expect(testCommand(viewer.sendCommand("switch-client -t other\n")) != null);
    _ = viewer.sendCommand("send-keys -t %0 -H 0x61\n");
    _ = viewer.next(.{ .tmux = .{ .block_end = .{} } });

    // The session changes before the end marker arrives.
    {
        const actions = viewer.next(.{ .tmux = .{ .session_changed = .{ .id = 1, .name = "other" } } });
        try testing.expect(testHasAction(actions, .windows));
        try testing.expect(testCommand(actions) == null);
    }

    // The marker still ends the switch, then list-windows goes out and
    // after that the keys the user typed meanwhile.
    {
        const actions = viewer.next(.{ .tmux = .{ .block_end = .{ .data = testMarker(&buf, 0) } } });
        try testing.expect(std.mem.startsWith(u8, testCommand(actions).?, "list-windows"));
    }
    {
        const actions = viewer.next(.{ .tmux = .{ .block_end = .{
            .data = "$1\t@3\t0\t1\t0\t%4\t80\t24\tb261,80x24,0,0,4\tb261,80x24,0,0,4\tA\tother",
        } } });
        try testing.expect(testHasAction(actions, .windows));
        try testing.expect(std.mem.startsWith(u8, testCommand(actions).?, "send-keys -t %0 -H 0x61\n"));
    }
    try testing.expectEqual(1, viewer.session_id);
    try testing.expectEqual(3, viewer.windows.items[0].id);
}

test "layout change reflects the zoom flag" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();
    try testAttach(&viewer, "$0\t@1\t1\t1\t0\t%1\t80\t24\t020a,80x24,0,0{40x24,0,0,1,39x24,41,0,2}\t020a,80x24,0,0{40x24,0,0,1,39x24,41,0,2}\tA\tshell");

    // Real tmux output for `resize-pane -Z -t %2`.
    {
        const actions = viewer.next(.{ .tmux = .{ .layout_change = .{
            .window_id = 1,
            .layout = "020a,80x24,0,0{40x24,0,0,1,39x24,41,0,2}",
            .visible_layout = "b25f,80x24,0,0,2",
            .raw_flags = "*Z",
        } } });
        try testing.expect(testHasAction(actions, .windows));
    }
    const window = &viewer.windows.items[0];
    try testing.expect(window.zoomed);
    try testing.expectEqual(2, window.visible_layout.?.content.pane);
    // Zooming hides panes, it doesn't close them.
    try testing.expectEqual(2, viewer.panes.count());

    // Unzoomed at a new size.
    _ = viewer.next(.{ .tmux = .{ .layout_change = .{
        .window_id = 1,
        .layout = "eb8f,100x30,0,0{50x30,0,0,1,49x30,51,0,2}",
        .visible_layout = "eb8f,100x30,0,0{50x30,0,0,1,49x30,51,0,2}",
        .raw_flags = "*",
    } } });
    try testing.expect(!window.zoomed);
    try testing.expect(window.visible_layout == null);
    try testing.expectEqual(100, window.width);
    try testing.expectEqual(30, window.height);
}

test "window notifications for our session and others" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();
    try testAttach(&viewer, "$0\t@0\t0\t1\t0\t%0\t80\t24\tb25d,80x24,0,0,0\tb25d,80x24,0,0,0\tA\tshell\n" ++
        "$0\t@1\t1\t0\t0\t%1\t80\t24\tb25e,80x24,0,0,1\tb25e,80x24,0,0,1\tA\tshell");

    // Renames of our windows are reported; the "unlinked" form only
    // when it is about one of ours.
    {
        const actions = viewer.next(.{ .tmux = .{ .window_renamed = .{ .id = 1, .name = "a b;c" } } });
        try testing.expectEqual(1, actions.len);
        try testing.expectEqual(1, actions[0].window_renamed.window_id);
        try testing.expectEqualStrings("a b;c", actions[0].window_renamed.name);
        try testing.expectEqualStrings("a b;c", viewer.windows.items[1].name);
    }
    try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .unlinked_window_renamed = .{ .id = 7, .name = "zzz" } } }).len);
    {
        const actions = viewer.next(.{ .tmux = .{ .unlinked_window_renamed = .{ .id = 0, .name = "top" } } });
        try testing.expectEqual(1, actions.len);
        try testing.expectEqualStrings("top", viewer.windows.items[0].name);
    }

    // Another session's current window is none of our business.
    try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .session_window_changed = .{ .session_id = 1, .window_id = 7 } } }).len);
    {
        const actions = viewer.next(.{ .tmux = .{ .session_window_changed = .{ .session_id = 0, .window_id = 1 } } });
        try testing.expectEqual(1, actions.len);
        try testing.expectEqual(1, actions[0].active_window);
        try testing.expect(!viewer.windows.items[0].active);
        try testing.expect(viewer.windows.items[1].active);
    }

    // Active pane changes carry the pane, for our windows only.
    try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .window_pane_changed = .{ .window_id = 7, .pane_id = 9 } } }).len);
    {
        const actions = viewer.next(.{ .tmux = .{ .window_pane_changed = .{ .window_id = 0, .pane_id = 4 } } });
        try testing.expectEqual(1, actions.len);
        try testing.expectEqual(0, actions[0].active_pane.window_id);
        try testing.expectEqual(4, actions[0].active_pane.pane_id);
        try testing.expectEqual(4, viewer.windows.items[0].active_pane);
    }

    // Other sessions' windows coming and going don't refresh our list.
    try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .unlinked_window_add = .{ .id = 7 } } }).len);
    try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .unlinked_window_close = .{ .id = 7 } } }).len);
    try testing.expect(viewer.command_queue.empty());

    // Quietly ignored.
    try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .session_renamed = .{ .id = 0, .name = "x" } } }).len);
    try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .pane_mode_changed = .{ .pane_id = 0 } } }).len);

    // Killing one of our windows is reported as unlinked, and refreshes.
    {
        const actions = viewer.next(.{ .tmux = .{ .unlinked_window_close = .{ .id = 1 } } });
        try testing.expect(std.mem.startsWith(u8, testCommand(actions).?, "list-windows"));
    }
    _ = viewer.next(.{ .tmux = .{ .block_end = .{
        .data = "$0\t@0\t0\t1\t0\t%0\t80\t24\tb25d,80x24,0,0,0\tb25d,80x24,0,0,0\tA\ttop",
    } } });
    try testing.expectEqual(1, viewer.windows.items.len);

    // So does a plain window close.
    {
        const actions = viewer.next(.{ .tmux = .{ .window_close = .{ .id = 0 } } });
        try testing.expect(std.mem.startsWith(u8, testCommand(actions).?, "list-windows"));
    }
}

test "window order changes refresh the window list" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();
    try testAttach(&viewer, "$0\t@0\t0\t1\t0\t%0\t80\t24\tb25d,80x24,0,0,0\tb25d,80x24,0,0,0\tA\tshell\n" ++
        "$0\t@1\t1\t0\t0\t%1\t80\t24\tb25e,80x24,0,0,1\tb25e,80x24,0,0,1\tA\tshell");

    // Someone else's subscription is not ours to act on.
    try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .subscription_changed = .{ .name = "other" } } }).len);
    try testing.expect(viewer.command_queue.empty());

    // An external `swap-window` changes nothing but our subscription.
    {
        const actions = viewer.next(.{ .tmux = .{ .subscription_changed = .{
            .name = Viewer.windows_subscription,
        } } });
        try testing.expect(std.mem.startsWith(u8, testCommand(actions).?, "list-windows"));
    }
    {
        const actions = viewer.next(.{ .tmux = .{ .block_end = .{
            .data = "$0\t@1\t0\t0\t0\t%1\t80\t24\tb25e,80x24,0,0,1\tb25e,80x24,0,0,1\tA\tshell\n" ++
                "$0\t@0\t1\t1\t0\t%0\t80\t24\tb25d,80x24,0,0,0\tb25d,80x24,0,0,0\tA\tshell",
        } } });
        try testing.expect(testHasAction(actions, .windows));
    }
    try testing.expectEqual(1, viewer.windows.items[0].id);
    try testing.expectEqual(0, viewer.windows.items[1].id);
    try testing.expect(viewer.command_queue.empty());

    // A refresh asked for by the caller goes out right away when nothing
    // is in flight, and waits its turn otherwise.
    try testing.expect(std.mem.startsWith(u8, testCommand(viewer.refreshWindows()).?, "list-windows"));
    try testing.expectEqual(0, viewer.refreshWindows().len);
    try testing.expectEqual(2, viewer.command_queue.len());
}

test "window list requests don't pile up" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();
    try testAttach(&viewer, "$0\t@0\t0\t1\t0\t%0\t80\t24\tb25d,80x24,0,0,0\tb25d,80x24,0,0,0\tA\tshell");

    // One in flight, one waiting: everything else that asks for the list
    // is answered by the one waiting.
    try testing.expect(testCommand(viewer.refreshWindows()) != null);
    _ = viewer.next(.{ .tmux = .{ .window_add = .{ .id = 1 } } });
    _ = viewer.next(.{ .tmux = .{ .window_close = .{ .id = 1 } } });
    _ = viewer.next(.{ .tmux = .{ .subscription_changed = .{
        .name = Viewer.windows_subscription,
    } } });
    try testing.expectEqual(0, viewer.refreshWindows().len);
    try testing.expectEqual(2, viewer.command_queue.len());

    // Once the waiting one is in flight, a new request waits again.
    {
        const actions = viewer.next(.{ .tmux = .{ .block_end = .{
            .data = "$0\t@0\t0\t1\t0\t%0\t80\t24\tb25d,80x24,0,0,0\tb25d,80x24,0,0,0\tA\tshell",
        } } });
        try testing.expect(std.mem.startsWith(u8, testCommand(actions).?, "list-windows"));
    }
    try testing.expectEqual(1, viewer.command_queue.len());
    _ = viewer.next(.{ .tmux = .{ .window_add = .{ .id = 1 } } });
    try testing.expectEqual(2, viewer.command_queue.len());
}

test "exit is reported once" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();
    try testAttach(&viewer, "$0\t@0\t0\t1\t0\t%0\t80\t24\tb25d,80x24,0,0,0\tb25d,80x24,0,0,0\tA\tshell");

    const actions = viewer.next(.{ .tmux = .exit });
    try testing.expectEqual(1, actions.len);
    try testing.expect(actions[0] == .exit);
    try testing.expectEqual(0, viewer.next(.{ .tmux = .exit }).len);
    try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .block_end = .{} } }).len);
}

test "detaching stops matching replies" {
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();
    try testAttach(&viewer, "$0\t@0\t0\t1\t0\t%0\t80\t24\tb25d,80x24,0,0,0\tb25d,80x24,0,0,0\tA\tshell");

    _ = viewer.capturePane(0);
    viewer.detach();

    // Replies to the detach write itself and to the capture: neither is
    // acted on, and nothing more is sent.
    try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .block_end = .{ .data = "content" } } }).len);
    try testing.expectEqual(0, viewer.sendCommand("set @affinities \"0\"\n").len);
}

test "replay of a real tmux control session" {
    // Bytes as tmux next-3.7 wrote them (CRLF line endings, a hook's
    // block with flags 0) in reply to the commands this viewer sends.
    var parser: control.Parser = .{ .buffer = .init(testing.allocator) };
    defer parser.deinit();
    var viewer = try Viewer.init(testing.io, testing.allocator);
    defer viewer.deinit();

    var commands: std.ArrayList(u8) = .empty;
    defer commands.deinit(testing.allocator);
    var renamed: bool = false;
    const feed = (struct {
        fn feed(
            p: *control.Parser,
            v: *Viewer,
            out: *std.ArrayList(u8),
            seen_rename: *bool,
            bytes: []const u8,
        ) !void {
            for (bytes) |byte| {
                const n = try p.put(byte) orelse continue;
                for (v.next(.{ .tmux = n })) |action| switch (action) {
                    .command => |c| {
                        // Only the command name, one per line.
                        const end = std.mem.indexOfScalar(u8, c, ' ') orelse c.len;
                        try out.appendSlice(testing.allocator, c[0..end]);
                        try out.append(testing.allocator, '\n');
                    },
                    .window_renamed => seen_rename.* = true,
                    .exit => return error.UnexpectedViewerExit,
                    else => {},
                };
            }
        }
    }).feed;

    try feed(&parser, &viewer, &commands, &renamed, "%begin 1793137358 279 0\r\n" ++
        "%end 1793137358 279 0\r\n" ++
        "%window-add @0\r\n" ++
        "%sessions-changed\r\n" ++
        "%session-changed $0 proto\r\n" ++
        "%window-renamed @0 tmux\r\n" ++
        "%begin 1793137358 280 1\r\nnext-3.7\r\n%end 1793137358 280 1\r\n" ++
        "%begin 1793137361 295 1\r\n" ++
        "$0\t@0\t0\t0\t0\t%0\t80\t24\tb25d,80x24,0,0,0\tb25d,80x24,0,0,0\tA\tbash\r\n" ++
        "$0\t@1\t1\t1\t1\t%2\t80\t24\t020a,80x24,0,0{40x24,0,0,1,39x24,41,0,2}\tb25f,80x24,0,0,2\tA\tmy win;x\r\n" ++
        "%end 1793137361 295 1\r\n" ++
        "%begin 1793135566 297 0\r\nHOOKED\r\n%end 1793135566 297 0\r\n");
    try testing.expectEqualStrings("display-message\nlist-windows\ncapture-pane\n", commands.items);
    try testing.expectEqualStrings("3.7", viewer.tmux_version[5..]);
    try testing.expectEqual(2, viewer.windows.items.len);
    try testing.expectEqualStrings("my win;x", viewer.windows.items[1].name);
    try testing.expect(viewer.windows.items[1].zoomed);
    try testing.expectEqual(2, viewer.windows.items[1].active_pane);

    // Captures of the three panes, then their state.
    commands.clearRetainingCapacity();
    for (0..12) |_| try feed(&parser, &viewer, &commands, &renamed, "%begin 1 1 1\r\n%end 1 1 1\r\n");
    try feed(&parser, &viewer, &commands, &renamed, "%begin 1793137362 296 1\r\n" ++
        "%0;38;0;1;default;none;0;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;;;0;23;8,16,24,32,40,48,56,64,72\r\n" ++
        "%1;38;0;1;default;none;0;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;;;0;23;8,16,24,32\r\n" ++
        "%2;38;0;1;default;none;0;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;;;0;23;8,16,24,32,40,48,56,64,72\r\n" ++
        "%end 1793137362 296 1\r\n");
    try testing.expectEqual(11, std.mem.count(u8, commands.items, "capture-pane\n"));
    try testing.expect(std.mem.endsWith(u8, commands.items, "list-panes\n"));
    try testing.expect(viewer.command_queue.empty());
    try testing.expectEqual(38, viewer.panes.getEntry(2).?.value_ptr.terminal.screens.active.cursor.x);

    // A GUI command and its end marker.
    commands.clearRetainingCapacity();
    try testing.expect(testCommand(viewer.sendCommand("set @affinities \"0,1\"\n")) != null);
    try feed(&parser, &viewer, &commands, &renamed, "%begin 1793137362 297 1\r\n%end 1793137362 297 1\r\n");
    try testing.expect(!viewer.command_queue.empty());
    try feed(&parser, &viewer, &commands, &renamed, "%begin 1793137362 298 1\r\nghostty-command-end 0\r\n%end 1793137362 298 1\r\n");
    try testing.expect(viewer.command_queue.empty());

    // Unzoom, a rename and the window going away.
    try feed(&parser, &viewer, &commands, &renamed, "%layout-change @1 020a,80x24,0,0{40x24,0,0,1,39x24,41,0,2} 020a,80x24,0,0{40x24,0,0,1,39x24,41,0,2} *\r\n" ++
        "%window-renamed @1 editor\r\n" ++
        "%unlinked-window-close @1\r\n");
    try testing.expect(!viewer.windows.items[1].zoomed);
    try testing.expect(renamed);
    try testing.expectEqualStrings("editor", viewer.windows.items[1].name);
    try testing.expectEqualStrings("list-windows\n", commands.items);
}
