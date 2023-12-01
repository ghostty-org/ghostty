//! Represents the renderer thread logic. The renderer thread is able to
//! be woken up to render.
pub const Thread = @This();

const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const renderer = @import("../renderer.zig");
const apprt = @import("../apprt.zig");
const BlockingQueue = @import("../blocking_queue.zig").BlockingQueue;
const tracy = @import("tracy");
const trace = tracy.trace;
const App = @import("../App.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.renderer_thread);

const DRAW_INTERVAL = 33; // 30 FPS
const CURSOR_BLINK_INTERVAL = 600;

/// The type used for sending messages to the IO thread. For now this is
/// hardcoded with a capacity. We can make this a comptime parameter in
/// the future if we want it configurable.
pub const Mailbox = BlockingQueue(renderer.Message, 64);

/// Allocator used for some state
alloc: std.mem.Allocator,

/// The main event loop for the application. The user data of this loop
/// is always the allocator used to create the loop. This is a convenience
/// so that users of the loop always have an allocator.
loop: xev.Loop,

/// This can be used to wake up the renderer and force a render safely from
/// any thread.
wakeup: xev.Async,
wakeup_c: xev.Completion = .{},

/// This can be used to stop the renderer on the next loop iteration.
stop: xev.Async,
stop_c: xev.Completion = .{},

/// The timer used for rendering
render_h: xev.Timer,
render_c: xev.Completion = .{},

/// The timer used for draw calls. Draw calls don't update from the
/// terminal state so they're much cheaper. They're used for animation
/// and are paused when the terminal is not focused.
draw_h: xev.Timer,
draw_c: xev.Completion = .{},
draw_active: bool = false,

/// The timer used for cursor blinking
cursor_h: xev.Timer,
cursor_c: xev.Completion = .{},
cursor_c_cancel: xev.Completion = .{},

/// The surface we're rendering to.
surface: *apprt.Surface,

/// The underlying renderer implementation.
renderer: *renderer.Renderer,

/// Pointer to the shared state that is used to generate the final render.
state: *renderer.State,

/// The mailbox that can be used to send this thread messages. Note
/// this is a blocking queue so if it is full you will get errors (or block).
mailbox: *Mailbox,

/// Mailbox to send messages to the app thread
app_mailbox: App.Mailbox,

flags: packed struct {
    /// This is true when a blinking cursor should be visible and false
    /// when it should not be visible. This is toggled on a timer by the
    /// thread automatically.
    cursor_blink_visible: bool = false,

    /// This is true when the inspector is active.
    has_inspector: bool = false,
} = .{},

/// Initialize the thread. This does not START the thread. This only sets
/// up all the internal state necessary prior to starting the thread. It
/// is up to the caller to start the thread with the threadMain entrypoint.
pub fn init(
    alloc: Allocator,
    surface: *apprt.Surface,
    renderer_impl: *renderer.Renderer,
    state: *renderer.State,
    app_mailbox: App.Mailbox,
) !Thread {
    // Create our event loop.
    var loop = try xev.Loop.init(.{});
    errdefer loop.deinit();

    // This async handle is used to "wake up" the renderer and force a render.
    var wakeup_h = try xev.Async.init();
    errdefer wakeup_h.deinit();

    // This async handle is used to stop the loop and force the thread to end.
    var stop_h = try xev.Async.init();
    errdefer stop_h.deinit();

    // The primary timer for rendering.
    var render_h = try xev.Timer.init();
    errdefer render_h.deinit();

    // Draw timer, see comments.
    var draw_h = try xev.Timer.init();
    errdefer draw_h.deinit();

    // Setup a timer for blinking the cursor
    var cursor_timer = try xev.Timer.init();
    errdefer cursor_timer.deinit();

    // The mailbox for messaging this thread
    var mailbox = try Mailbox.create(alloc);
    errdefer mailbox.destroy(alloc);

    return Thread{
        .alloc = alloc,
        .loop = loop,
        .wakeup = wakeup_h,
        .stop = stop_h,
        .render_h = render_h,
        .draw_h = draw_h,
        .cursor_h = cursor_timer,
        .surface = surface,
        .renderer = renderer_impl,
        .state = state,
        .mailbox = mailbox,
        .app_mailbox = app_mailbox,
    };
}

/// Clean up the thread. This is only safe to call once the thread
/// completes executing; the caller must join prior to this.
pub fn deinit(self: *Thread) void {
    self.stop.deinit();
    self.wakeup.deinit();
    self.render_h.deinit();
    self.draw_h.deinit();
    self.cursor_h.deinit();
    self.loop.deinit();

    // Nothing can possibly access the mailbox anymore, destroy it.
    self.mailbox.destroy(self.alloc);
}

/// The main entrypoint for the thread.
pub fn threadMain(self: *Thread) void {
    // Call child function so we can use errors...
    self.threadMain_() catch |err| {
        // In the future, we should expose this on the thread struct.
        log.warn("error in renderer err={}", .{err});
    };
}

fn threadMain_(self: *Thread) !void {
    defer log.debug("renderer thread exited", .{});
    tracy.setThreadName("renderer");

    // Run our thread start/end callbacks. This is important because some
    // renderers have to do per-thread setup. For example, OpenGL has to set
    // some thread-local state since that is how it works.
    try self.renderer.threadEnter(self.surface);
    defer self.renderer.threadExit();

    // Start the async handlers
    self.wakeup.wait(&self.loop, &self.wakeup_c, Thread, self, wakeupCallback);
    self.stop.wait(&self.loop, &self.stop_c, Thread, self, stopCallback);

    // Send an initial wakeup message so that we render right away.
    try self.wakeup.notify();

    // Start blinking the cursor.
    self.cursor_h.run(
        &self.loop,
        &self.cursor_c,
        CURSOR_BLINK_INTERVAL,
        Thread,
        self,
        cursorTimerCallback,
    );

    // Start the draw timer
    self.startDrawTimer();

    // Run
    log.debug("starting renderer thread", .{});
    defer log.debug("starting renderer thread shutdown", .{});
    _ = try self.loop.run(.until_done);
}

fn startDrawTimer(self: *Thread) void {
    // If our renderer doesn't suppoort animations then we never run this.
    if (!@hasDecl(renderer.Renderer, "hasAnimations")) return;
    if (!self.renderer.hasAnimations()) return;

    // Set our active state so it knows we're running. We set this before
    // even checking the active state in case we have a pending shutdown.
    self.draw_active = true;

    // If our draw timer is already active, then we don't have to do anything.
    if (self.draw_c.state() == .active) return;

    // Start the timer which loops
    self.draw_h.run(
        &self.loop,
        &self.draw_c,
        DRAW_INTERVAL,
        Thread,
        self,
        drawCallback,
    );
}

fn stopDrawTimer(self: *Thread) void {
    // This will stop the draw on the next iteration.
    self.draw_active = false;
}

/// Drain the mailbox.
fn drainMailbox(self: *Thread) !void {
    const zone = trace(@src());
    defer zone.end();

    while (self.mailbox.pop()) |message| {
        log.debug("mailbox message={}", .{message});
        switch (message) {
            .focus => |v| {
                // Set it on the renderer
                try self.renderer.setFocus(v);

                if (!v) {
                    // Stop the draw timer
                    self.stopDrawTimer();

                    // If we're not focused, then we stop the cursor blink
                    if (self.cursor_c.state() == .active and
                        self.cursor_c_cancel.state() == .dead)
                    {
                        self.cursor_h.cancel(
                            &self.loop,
                            &self.cursor_c,
                            &self.cursor_c_cancel,
                            void,
                            null,
                            cursorCancelCallback,
                        );
                    }
                } else {
                    // Start the draw timer
                    self.startDrawTimer();

                    // If we're focused, we immediately show the cursor again
                    // and then restart the timer.
                    if (self.cursor_c.state() != .active) {
                        self.flags.cursor_blink_visible = true;
                        self.cursor_h.run(
                            &self.loop,
                            &self.cursor_c,
                            CURSOR_BLINK_INTERVAL,
                            Thread,
                            self,
                            cursorTimerCallback,
                        );
                    }
                }
            },

            .reset_cursor_blink => {
                self.flags.cursor_blink_visible = true;
                if (self.cursor_c.state() == .active) {
                    self.cursor_h.reset(
                        &self.loop,
                        &self.cursor_c,
                        &self.cursor_c_cancel,
                        CURSOR_BLINK_INTERVAL,
                        Thread,
                        self,
                        cursorTimerCallback,
                    );
                }
            },

            .font_size => |size| {
                try self.renderer.setFontSize(size);
            },

            .foreground_color => |color| {
                self.renderer.foreground_color = color;
            },

            .background_color => |color| {
                self.renderer.background_color = color;
            },

            .cursor_color => |color| {
                self.renderer.cursor_color = color;
            },

            .resize => |v| {
                try self.renderer.setScreenSize(v.screen_size, v.padding);
            },

            .change_config => |config| {
                defer config.alloc.destroy(config.ptr);
                try self.renderer.changeConfig(config.ptr);

                // Stop and start the draw timer to capture the new
                // hasAnimations value.
                self.stopDrawTimer();
                self.startDrawTimer();
            },

            .inspector => |v| self.flags.has_inspector = v,
        }
    }
}

fn wakeupCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.err("error in wakeup err={}", .{err});
        return .rearm;
    };

    const zone = trace(@src());
    defer zone.end();

    const t = self_.?;

    // When we wake up, we check the mailbox. Mailbox producers should
    // wake up our thread after publishing.
    t.drainMailbox() catch |err|
        log.err("error draining mailbox err={}", .{err});

    // If the timer is already active then we don't have to do anything.
    if (t.render_c.state() == .active) return .rearm;

    // Timer is not active, let's start it
    t.render_h.run(
        &t.loop,
        &t.render_c,
        10,
        Thread,
        t,
        renderCallback,
    );

    return .rearm;
}

fn drawCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    const t = self_ orelse {
        // This shouldn't happen so we log it.
        log.warn("render callback fired without data set", .{});
        return .disarm;
    };

    // If we're doing single-threaded GPU calls then we just wake up the
    // app thread to redraw at this point.
    if (renderer.Renderer == renderer.OpenGL and
        renderer.OpenGL.single_threaded_draw)
    {
        _ = t.app_mailbox.push(
            .{ .redraw_surface = t.surface },
            .{ .instant = {} },
        );
    } else {
        t.renderer.drawFrame(t.surface) catch |err|
            log.warn("error drawing err={}", .{err});
    }

    // Only continue if we're still active
    if (t.draw_active) {
        t.draw_h.run(&t.loop, &t.draw_c, DRAW_INTERVAL, Thread, t, drawCallback);
    }

    return .disarm;
}

fn renderCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    const zone = trace(@src());
    defer zone.end();

    _ = r catch unreachable;
    const t = self_ orelse {
        // This shouldn't happen so we log it.
        log.warn("render callback fired without data set", .{});
        return .disarm;
    };

    // If we have an inspector, let the app know we want to rerender that.
    if (t.flags.has_inspector) {
        _ = t.app_mailbox.push(.{ .redraw_inspector = t.surface }, .{ .instant = {} });
    }

    // Update our frame data
    t.renderer.updateFrame(
        t.surface,
        t.state,
        t.flags.cursor_blink_visible,
    ) catch |err|
        log.warn("error rendering err={}", .{err});

    // If we're doing single-threaded GPU calls then we also wake up the
    // app thread to redraw at this point.
    if (renderer.Renderer == renderer.OpenGL and
        renderer.OpenGL.single_threaded_draw)
    {
        _ = t.app_mailbox.push(.{ .redraw_surface = t.surface }, .{ .instant = {} });
        return .disarm;
    }

    // Draw
    t.renderer.drawFrame(t.surface) catch |err|
        log.warn("error drawing err={}", .{err});

    return .disarm;
}

fn cursorTimerCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    const zone = trace(@src());
    defer zone.end();

    _ = r catch |err| switch (err) {
        // This is sent when our timer is canceled. That's fine.
        error.Canceled => return .disarm,

        else => {
            log.warn("error in cursor timer callback err={}", .{err});
            unreachable;
        },
    };

    const t = self_ orelse {
        // This shouldn't happen so we log it.
        log.warn("render callback fired without data set", .{});
        return .disarm;
    };

    t.flags.cursor_blink_visible = !t.flags.cursor_blink_visible;
    t.wakeup.notify() catch {};

    t.cursor_h.run(&t.loop, &t.cursor_c, CURSOR_BLINK_INTERVAL, Thread, t, cursorTimerCallback);
    return .disarm;
}

fn cursorCancelCallback(
    _: ?*void,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.CancelError!void,
) xev.CallbackAction {
    // This makes it easier to work across platforms where different platforms
    // support different sets of errors, so we just unify it.
    const CancelError = xev.Timer.CancelError || error{
        Canceled,
        NotFound,
        Unexpected,
    };

    _ = r catch |err| switch (@as(CancelError, @errorCast(err))) {
        error.Canceled => {}, // success
        error.NotFound => {}, // completed before it could cancel
        else => {
            log.warn("error in cursor cancel callback err={}", .{err});
            unreachable;
        },
    };

    return .disarm;
}

// fn prepFrameCallback(h: *libuv.Prepare) void {
//     _ = h;
//
//     tracy.frameMark();
// }

fn stopCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    self_.?.loop.stop();
    return .disarm;
}
