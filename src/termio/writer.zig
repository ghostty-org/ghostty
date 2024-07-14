const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const xev = @import("xev");
const renderer = @import("../renderer.zig");
const termio = @import("../termio.zig");
const BlockingQueue = @import("../blocking_queue.zig").BlockingQueue;

const log = std.log.scoped(.io_writer);

/// A mailbox used for storing messages that is periodically drained.
/// Typically used by a multi-threaded application. The capacity is
/// hardcoded to a value that empirically has made sense for Ghostty usage
/// but I'm open to changing it with good arguments.
pub const Mailbox = BlockingQueue(termio.Message, 64);

/// The location to where write-related messages are sent.
pub const Writer = union(enum) {
    // /// Write messages to an unbounded list backed by an allocator.
    // /// This is useful for single-threaded applications where you're not
    // /// afraid of running out of memory. You should be careful that you're
    // /// processing this in a timely manner though since some heavy workloads
    // /// will produce a LOT of messages.
    // ///
    // /// At the time of authoring this, the primary use case for this is
    // /// testing more than anything, but it probably will have a use case
    // /// in libghostty eventually.
    // unbounded: std.ArrayList(termio.Message),

    /// Write messages to a SPSC mailbox for multi-threaded applications.
    mailbox: struct {
        mailbox: *Mailbox,
        wakeup: xev.Async,
    },

    /// Init the mailbox writer.
    pub fn initMailbox(alloc: Allocator) !Writer {
        var mailbox = try Mailbox.create(alloc);
        errdefer mailbox.destroy(alloc);

        var wakeup = try xev.Async.init();
        errdefer wakeup.deinit();

        return .{ .mailbox = .{ .mailbox = mailbox, .wakeup = wakeup } };
    }

    pub fn deinit(self: *Writer, alloc: Allocator) void {
        switch (self.*) {
            .mailbox => |*v| {
                v.mailbox.destroy(alloc);
                v.wakeup.deinit();
            },
        }
    }

    /// Sends the given message without notifying there are messages.
    ///
    /// If the optional mutex is given, it must already be LOCKED. If the
    /// send would block, we'll unlock this mutex, resend the message, and
    /// lock it again. This handles an edge case where mailboxes are full.
    /// This may not apply to all writer types.
    pub fn send(
        self: *Writer,
        msg: termio.Message,
        mutex: ?*std.Thread.Mutex,
    ) void {
        switch (self.*) {
            .mailbox => |*mb| send: {
                // Try to write to the mailbox with an instant timeout. This is the
                // fast path because we can queue without a lock.
                if (mb.mailbox.push(msg, .{ .instant = {} }) > 0) break :send;

                // If we enter this conditional, the mailbox is full. We wake up
                // the writer thread so that it can process messages to clear up
                // space. However, the writer thread may require the renderer
                // lock so we need to unlock.
                mb.wakeup.notify() catch |err| {
                    log.warn("failed to wake up writer, data will be dropped err={}", .{err});
                    return;
                };

                // Unlock the renderer state so the writer thread can acquire it.
                // Then try to queue our message before continuing. This is a very
                // slow path because we are having a lot of contention for data.
                // But this only gets triggered in certain pathological cases.
                //
                // Note that writes themselves don't require a lock, but there
                // are other messages in the writer mailbox (resize, focus) that
                // could acquire the lock. This is why we have to release our lock
                // here.
                if (mutex) |m| m.unlock();
                defer if (mutex) |m| m.lock();
                _ = mb.mailbox.push(msg, .{ .forever = {} });
            },
        }
    }

    /// Notify that there are new messages. This may be a noop depending
    /// on the writer type.
    pub fn notify(self: *Writer) void {
        switch (self.*) {
            .mailbox => |v| v.wakeup.notify() catch |err| {
                log.warn("failed to notify writer, data will be dropped err={}", .{err});
            },
        }
    }
};