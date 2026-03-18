const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const xev = @import("../../global.zig").xev;
const apprt = @import("../../apprt.zig");
const BlockingQueue = @import("../../datastruct/main.zig").BlockingQueue;
const internal_os = @import("../../os/main.zig");

const log = std.log.scoped(.file_check);

const Thread = @This();

const Mailbox = BlockingQueue(Message, 32);

pub const Message = union(enum) {
    check: CheckRequest,
};

pub const CheckRequest = struct {
    word: [255]u8 = undefined,
    word_len: u8 = 0,
    pwd: [std.fs.max_path_bytes]u8 = undefined,
    pwd_len: u16 = 0,

    pub fn wordSlice(self: *const CheckRequest) []const u8 {
        return self.word[0..self.word_len];
    }

    pub fn pwdSlice(self: *const CheckRequest) []const u8 {
        return self.pwd[0..self.pwd_len];
    }
};

pub const Options = struct {
    result_cb: *const fn (result: apprt.surface.Message.FileCheckResult, ud: ?*anyopaque) void,
    result_userdata: ?*anyopaque = null,
};

alloc: Allocator,
mailbox: *Mailbox,
loop: xev.Loop,
wakeup: xev.Async,
wakeup_c: xev.Completion = .{},
stop: xev.Async,
stop_c: xev.Completion = .{},
opts: Options,

pub fn init(alloc: Allocator, opts: Options) !Thread {
    var mailbox = try Mailbox.create(alloc);
    errdefer mailbox.destroy(alloc);

    var loop = try xev.Loop.init(.{});
    errdefer loop.deinit();

    var wakeup_h = try xev.Async.init();
    errdefer wakeup_h.deinit();

    var stop_h = try xev.Async.init();
    errdefer stop_h.deinit();

    return .{
        .alloc = alloc,
        .mailbox = mailbox,
        .loop = loop,
        .wakeup = wakeup_h,
        .stop = stop_h,
        .opts = opts,
    };
}

pub fn deinit(self: *Thread) void {
    self.wakeup.deinit();
    self.stop.deinit();
    self.loop.deinit();
    self.mailbox.destroy(self.alloc);
}

pub fn threadMain(self: *Thread) void {
    self.threadMain_() catch |err| {
        log.err("file check thread error: {}", .{err});
    };
}

fn threadMain_(self: *Thread) !void {
    if (comptime builtin.os.tag.isDarwin()) {
        internal_os.macos.pthread_setname_np(&"file-check".*);
        const class: internal_os.macos.QosClass = .utility;
        if (internal_os.macos.setQosClass(class)) {
            log.debug("thread QoS class set class={}", .{class});
        } else |err| {
            log.warn("error setting QoS class err={}", .{err});
        }
    }

    self.wakeup.wait(&self.loop, &self.wakeup_c, Thread, self, wakeupCallback);
    self.stop.wait(&self.loop, &self.stop_c, Thread, self, stopCallback);

    try self.wakeup.notify();

    log.debug("starting file check thread", .{});

    while (true) {
        if (self.loop.stopped()) {
            while (self.mailbox.pop()) |msg| {
                _ = msg;
            }
            return;
        }
        try self.loop.run(.once);
    }
}

fn wakeupCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.warn("error in wakeup err={}", .{err});
        return .rearm;
    };
    const self = self_.?;
    self.drainMailbox();
    return .rearm;
}

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

fn drainMailbox(self: *Thread) void {
    while (self.mailbox.pop()) |msg| {
        self.processMessage(msg);
    }
}

fn processMessage(self: *Thread, msg: Message) void {
    switch (msg) {
        .check => |req| self.handleCheck(req),
    }
}

fn handleCheck(self: *Thread, req: CheckRequest) void {
    const word = req.wordSlice();
    const pwd = req.pwdSlice();

    const resolved = std.fs.path.resolve(self.alloc, &.{ pwd, word }) catch {
        self.sendResult(word, pwd, null);
        return;
    };
    defer self.alloc.free(resolved);

    const stat = std.fs.cwd().statFile(resolved) catch {
        self.sendResult(word, pwd, null);
        return;
    };

    if (stat.kind != .file) {
        self.sendResult(word, pwd, null);
        return;
    }

    self.sendResult(word, pwd, resolved);
}

fn sendResult(self: *Thread, word: []const u8, pwd: []const u8, resolved: ?[]const u8) void {
    var result: apprt.surface.Message.FileCheckResult = .{
        .cache_key = std.hash.Wyhash.hash(0, word) ^ std.hash.Wyhash.hash(1, pwd),
    };

    if (resolved) |path| {
        if (apprt.surface.Message.WriteReq.init(self.alloc, path)) |req| {
            result.resolved_path = req;
        } else |_| {
            return;
        }
    }

    self.opts.result_cb(result, self.opts.result_userdata);
}

pub fn submit(self: *Thread, word: []const u8, pwd: []const u8) void {
    if (word.len > 255 or pwd.len > std.fs.max_path_bytes) return;

    var req: CheckRequest = .{};
    @memcpy(req.word[0..word.len], word);
    req.word_len = @intCast(word.len);
    @memcpy(req.pwd[0..pwd.len], pwd);
    req.pwd_len = @intCast(pwd.len);

    _ = self.mailbox.push(.{ .check = req }, .{ .instant = {} });
    self.wakeup.notify() catch {};
}
