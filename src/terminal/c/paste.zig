const std = @import("std");
const lib = @import("../lib.zig");
const paste = @import("../../input/paste.zig");
const terminal_paste_pkg = @import("../paste.zig");
const clipboard = @import("../clipboard.zig");
const io = @import("io.zig");
const terminal_c = @import("terminal.zig");
const Terminal = terminal_c.Terminal;
const ClipboardContent = terminal_c.ClipboardContent;
const ClipboardRead = terminal_c.ClipboardRead;
const ClipboardReadReply = terminal_c.ClipboardReadReply;
const Result = @import("result.zig").Result;

/// Why a paste happened. The flat C form of the Zig tagged union
/// (terminal.paste.Source); the location rides alongside in
/// GhosttyPaste and only applies to a clipboard paste.
///
/// C: GhosttyPasteSource
pub const Source = lib.Enum(lib.target, &.{
    "clipboard",
    "text",
});

/// A paste of clipboard contents into the terminal. Sized struct.
///
/// C: GhosttyPaste
pub const Request = extern struct {
    size: usize = @sizeOf(Request),
    location: clipboard.Location,
    source: Source,
    mimes: ?[*]const lib.String,
    mimes_len: usize,
    reader: io.MimeReader,
    allow_unsafe: bool,
};

pub fn terminal_paste(
    terminal_: Terminal,
    req_: ?*const Request,
    out_written: ?*bool,
) callconv(lib.calling_conv) Result {
    const wrapper = terminal_ orelse return .invalid_value;
    const req = req_ orelse return .invalid_value;

    // Every field is required; a smaller size is a caller from a
    // different ABI version than any this struct has had.
    if (req.size < @sizeOf(Request)) return .invalid_value;

    // The handler always has a write_pty trampoline that no-ops without
    // a C callback, so the "nothing can be written" check is ours.
    if (wrapper.effects.write_pty == null) return .invalid_value;

    const c_mimes: []const lib.String = if (req.mimes) |ptr|
        ptr[0..req.mimes_len]
    else
        &.{};

    // Only a paste with something to read needs a reader.
    if (c_mimes.len > 0 and !req.reader.valid()) return .invalid_value;

    // A paste carries a handful of representations, so keep the common
    // case allocation-free.
    var sfa = std.heap.stackFallback(256, wrapper.terminal.gpa());
    const alloc = sfa.get();
    const mimes = alloc.alloc([]const u8, c_mimes.len) catch return .out_of_memory;
    defer alloc.free(mimes);
    for (mimes, c_mimes) |*mime, c_mime| mime.* = c_mime.ptr[0..c_mime.len];

    const written = wrapper.stream.handler.paste(.{
        .source = switch (req.source) {
            .clipboard => .{ .clipboard = req.location },
            .text => .text,
        },
        .contents = .{ .reader = .{
            .mimes = mimes,
            .read = .{ .ctx = @constCast(req), .read_fn = &readTrampoline },
        } },
        .allow_unsafe = req.allow_unsafe,
    }) catch |err| return switch (err) {
        error.UnsafePaste => .rejected,
        error.NoWritePty => .invalid_value,
        error.OutOfMemory => .out_of_memory,
        error.ReadFailed,
        error.EntropyUnavailable,
        error.Canceled,
        => .io_error,
    };
    if (out_written) |ptr| ptr.* = written;
    return .success;
}

/// The sink handed to the C read callback: a GhosttyWriter over the
/// Zig sink, remembering whether the sink itself failed so that can be
/// told apart from the callback failing to read.
const Sink = struct {
    writer: *std.Io.Writer,
    write_failed: bool = false,

    fn write(
        userdata: ?*anyopaque,
        data: [*]const u8,
        len: usize,
    ) callconv(lib.calling_conv) bool {
        const self: *Sink = @ptrCast(@alignCast(userdata.?));
        self.writer.writeAll(data[0..len]) catch {
            self.write_failed = true;
            return false;
        };
        return true;
    }
};

fn readTrampoline(
    ctx: ?*anyopaque,
    mime: []const u8,
    writer: *std.Io.Writer,
) clipboard.MimeReader.Error!void {
    const req: *const Request = @ptrCast(@alignCast(ctx.?));
    var sink: Sink = .{ .writer = writer };
    if (!req.reader.read.?(req.reader.userdata, .init(mime), .{
        .write = &Sink.write,
        .userdata = &sink,
    })) {
        return if (sink.write_failed) error.WriteFailed else error.ReadFailed;
    }
}

pub fn is_safe(data: ?[*]const u8, len: usize) callconv(lib.calling_conv) bool {
    const slice: []const u8 = if (data) |v| v[0..len] else &.{};
    return paste.isSafe(slice);
}

pub fn encode(
    data: ?[*]u8,
    data_len: usize,
    bracketed: bool,
    out_: ?[*]u8,
    out_len: usize,
    out_written: *usize,
) callconv(lib.calling_conv) Result {
    const slice: []u8 = if (data) |v| v[0..data_len] else &.{};
    const result = paste.encode(slice, .{ .bracketed = bracketed });

    const total = result[0].len + result[1].len + result[2].len;
    out_written.* = total;

    const out: []u8 = if (out_) |o| o[0..out_len] else &.{};
    if (out.len < total) return .out_of_space;

    var offset: usize = 0;
    for (result) |segment| {
        @memcpy(out[offset..][0..segment.len], segment);
        offset += segment.len;
    }

    return .success;
}

test "encode bracketed" {
    const testing = std.testing;
    const input = try testing.allocator.dupe(u8, "hello");
    defer testing.allocator.free(input);
    var buf: [64]u8 = undefined;
    var written: usize = 0;
    const result = encode(input.ptr, input.len, true, &buf, buf.len, &written);
    try testing.expectEqual(.success, result);
    try testing.expectEqualStrings("\x1b[200~hello\x1b[201~", buf[0..written]);
}

test "encode unbracketed no newlines" {
    const testing = std.testing;
    const input = try testing.allocator.dupe(u8, "hello");
    defer testing.allocator.free(input);
    var buf: [64]u8 = undefined;
    var written: usize = 0;
    const result = encode(input.ptr, input.len, false, &buf, buf.len, &written);
    try testing.expectEqual(.success, result);
    try testing.expectEqualStrings("hello", buf[0..written]);
}

test "encode unbracketed newlines" {
    const testing = std.testing;
    const input = try testing.allocator.dupe(u8, "hello\nworld");
    defer testing.allocator.free(input);
    var buf: [64]u8 = undefined;
    var written: usize = 0;
    const result = encode(input.ptr, input.len, false, &buf, buf.len, &written);
    try testing.expectEqual(.success, result);
    try testing.expectEqualStrings("hello\rworld", buf[0..written]);
}

test "encode strip unsafe bytes" {
    const testing = std.testing;
    const input = try testing.allocator.dupe(u8, "hel\x1blo\x00world");
    defer testing.allocator.free(input);
    var buf: [64]u8 = undefined;
    var written: usize = 0;
    const result = encode(input.ptr, input.len, true, &buf, buf.len, &written);
    try testing.expectEqual(.success, result);
    try testing.expectEqualStrings("\x1b[200~hel lo world\x1b[201~", buf[0..written]);
}

test "encode with insufficient buffer" {
    const testing = std.testing;
    const input = try testing.allocator.dupe(u8, "hello");
    defer testing.allocator.free(input);
    var buf: [1]u8 = undefined;
    var written: usize = 0;
    const result = encode(input.ptr, input.len, true, &buf, buf.len, &written);
    try testing.expectEqual(.out_of_space, result);
    try testing.expectEqual(17, written);
}

test "encode with null buffer" {
    const testing = std.testing;
    const input = try testing.allocator.dupe(u8, "hello");
    defer testing.allocator.free(input);
    var written: usize = 0;
    const result = encode(input.ptr, input.len, true, null, 0, &written);
    try testing.expectEqual(.out_of_space, result);
    try testing.expectEqual(17, written);
}

test "is_safe with safe data" {
    const testing = std.testing;
    const safe = "hello world";
    try testing.expect(is_safe(safe.ptr, safe.len));
}

test "is_safe with newline" {
    const testing = std.testing;
    const unsafe = "hello\nworld";
    try testing.expect(!is_safe(unsafe.ptr, unsafe.len));
}

test "is_safe with bracketed paste end" {
    const testing = std.testing;
    const unsafe = "hello\x1b[201~world";
    try testing.expect(!is_safe(unsafe.ptr, unsafe.len));
}

test "is_safe with empty data" {
    const testing = std.testing;
    const empty = "";
    try testing.expect(is_safe(empty.ptr, 0));
}

test "is_safe with null empty data" {
    const testing = std.testing;
    try testing.expect(is_safe(null, 0));
}

/// Capture state for the terminal_paste tests: every pty write and the
/// clipboard reads that follow a paste event.
const TerminalPasteCapture = struct {
    var written: [1024]u8 = undefined;
    var written_len: usize = 0;
    var write_count: usize = 0;
    var read_count: usize = 0;
    var last_read_granted: bool = false;

    fn reset() void {
        written_len = 0;
        write_count = 0;
        read_count = 0;
        last_read_granted = false;
    }

    fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
        @memcpy(written[written_len..][0..len], ptr[0..len]);
        written_len += len;
        write_count += 1;
    }

    fn clipboardRead(_: Terminal, _: ?*anyopaque, request: *const ClipboardRead) callconv(lib.calling_conv) void {
        read_count += 1;
        last_read_granted = request.granted;
        const contents = [_]ClipboardContent{.{
            .mime = .init(@as([]const u8, "text/plain")),
            .data = .init(@as([]const u8, "Ghostty")),
        }};
        request.reply(request, &.{
            .size = @sizeOf(ClipboardReadReply),
            .result = .success,
            .contents = &contents,
            .contents_len = contents.len,
            .available = null,
            .available_len = 0,
            .remember = false,
        });
    }

    fn writtenSlice() []const u8 {
        return written[0..written_len];
    }

    /// The representations a test paste serves: the MIME list for the
    /// request and the data the read callback streams, in pieces.
    const Contents = struct {
        mimes: [2]lib.String = undefined,
        data: [2][]const u8 = undefined,
        len: usize = 0,
        reads: [2]usize = @splat(0),
        fail: bool = false,

        fn init(entries: []const struct { []const u8, []const u8 }) Contents {
            var self: Contents = .{};
            for (entries) |entry| {
                self.mimes[self.len] = .init(entry[0]);
                self.data[self.len] = entry[1];
                self.len += 1;
            }
            return self;
        }

        fn request(self: *Contents) Request {
            return .{
                .location = .standard,
                .source = .clipboard,
                .mimes = &self.mimes,
                .mimes_len = self.len,
                .reader = .{ .read = &read, .userdata = self },
                .allow_unsafe = false,
            };
        }

        fn read(userdata: ?*anyopaque, mime: lib.String, writer: io.Writer) callconv(lib.calling_conv) bool {
            const self: *Contents = @ptrCast(@alignCast(userdata.?));
            // The mime is the exact string from the request's list, so
            // identifying it by pointer works.
            const index: usize = for (self.mimes[0..self.len], 0..) |m, i| {
                if (m.ptr == mime.ptr and m.len == mime.len) break i;
            } else return false;
            self.reads[index] += 1;
            if (self.fail) return false;
            const data = self.data[index];
            var offset: usize = 0;
            while (offset < data.len) {
                const n = @min(3, data.len - offset);
                if (!writer.write.?(writer.userdata, data[offset..].ptr, n)) return false;
                offset += n;
            }
            return true;
        }
    };
};

test "terminal_paste null handling" {
    const testing = std.testing;
    const S = TerminalPasteCapture;

    var t: Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(&lib.alloc.test_allocator, &t, 80, 24));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.set(t, .write_pty, @ptrCast(&S.writePty)));

    var written: bool = true;
    var contents: S.Contents = .init(&.{.{ "text/plain", "hello" }});
    const req = contents.request();
    try testing.expectEqual(Result.invalid_value, terminal_paste(null, &req, &written));
    try testing.expectEqual(Result.invalid_value, terminal_paste(t, null, &written));
    try testing.expect(written);

    // A size smaller than the struct is rejected.
    var small = req;
    small.size = @sizeOf(usize);
    try testing.expectEqual(Result.invalid_value, terminal_paste(t, &small, &written));

    // MIME types without a reader are rejected; none at all is fine.
    var unreadable = req;
    unreadable.reader.read = null;
    try testing.expectEqual(Result.invalid_value, terminal_paste(t, &unreadable, &written));
    unreadable.mimes = null;
    unreadable.mimes_len = 0;
    try testing.expectEqual(Result.success, terminal_paste(t, &unreadable, &written));
    try testing.expect(!written);
}

test "terminal_paste without write_pty is invalid" {
    const testing = std.testing;
    const S = TerminalPasteCapture;
    S.reset();

    var t: Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(&lib.alloc.test_allocator, &t, 80, 24));
    defer terminal_c.free(t);

    var contents: S.Contents = .init(&.{.{ "text/plain", "hello" }});
    const req = contents.request();
    try testing.expectEqual(Result.invalid_value, terminal_paste(t, &req, null));
}

test "terminal_paste text and unsafe" {
    const testing = std.testing;
    const S = TerminalPasteCapture;
    S.reset();

    var t: Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(&lib.alloc.test_allocator, &t, 80, 24));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.set(t, .write_pty, @ptrCast(&S.writePty)));

    // Plain text, NULL out_written pointer is fine. The text is read
    // once, the image never.
    var contents: S.Contents = .init(&.{
        .{ "image/png", "\x89PNG" },
        .{ "text/plain", "hel\x1blo" },
    });
    const req = contents.request();
    try testing.expectEqual(Result.success, terminal_paste(t, &req, null));
    try testing.expectEqualStrings("hel lo", S.writtenSlice());
    try testing.expectEqual(@as(usize, 1), S.write_count);
    try testing.expectEqual(@as(usize, 0), contents.reads[0]);
    try testing.expectEqual(@as(usize, 1), contents.reads[1]);

    // Unsafe is refused with nothing written, then allowed.
    S.reset();
    var written: bool = false;
    var unsafe_contents: S.Contents = .init(&.{.{ "text/plain", "rm -rf /\n" }});
    var unsafe = unsafe_contents.request();
    try testing.expectEqual(Result.rejected, terminal_paste(t, &unsafe, &written));
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expect(!written);
    try testing.expectEqual(@as(usize, 1), unsafe_contents.reads[0]);

    unsafe.allow_unsafe = true;
    try testing.expectEqual(Result.success, terminal_paste(t, &unsafe, &written));
    try testing.expect(written);
    try testing.expectEqualStrings("rm -rf /\r", S.writtenSlice());
    try testing.expectEqual(@as(usize, 2), unsafe_contents.reads[0]);

    // Bracketed paste mode frames the text through the real mode path.
    S.reset();
    const decset = "\x1b[?2004h";
    terminal_c.vt_write(t, decset, decset.len);
    try testing.expectEqual(Result.success, terminal_paste(t, &req, &written));
    try testing.expect(written);
    try testing.expectEqualStrings("\x1b[200~hel lo\x1b[201~", S.writtenSlice());

    // No text representation writes nothing and reads nothing.
    S.reset();
    var image: S.Contents = .init(&.{.{ "image/png", "\x89PNG" }});
    const image_req = image.request();
    try testing.expectEqual(Result.success, terminal_paste(t, &image_req, &written));
    try testing.expect(!written);
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expectEqual(@as(usize, 0), image.reads[0]);

    // A failing reader is an I/O error.
    S.reset();
    contents.fail = true;
    try testing.expectEqual(Result.io_error, terminal_paste(t, &req, &written));
    try testing.expectEqual(@as(usize, 0), S.write_count);
}

test "terminal_paste event" {
    const testing = std.testing;
    const S = TerminalPasteCapture;
    S.reset();

    var t: Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(&lib.alloc.test_allocator, &t, 80, 24));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.set(t, .write_pty, @ptrCast(&S.writePty)));
    t.?.terminal.modes.set(.kitty_paste_events, true);

    // Without a clipboard_read callback the paste stays text.
    var written: bool = false;
    var contents: S.Contents = .init(&.{
        .{ "text/plain", "secret" },
        .{ "image/png", "\x89PNG" },
    });
    var req = contents.request();
    req.location = .primary;
    try testing.expectEqual(Result.success, terminal_paste(t, &req, &written));
    try testing.expect(written);
    try testing.expectEqualStrings("secret", S.writtenSlice());

    // With one, an event is sent listing every MIME type and no data
    // is read, let alone written.
    S.reset();
    contents.reads = @splat(0);
    try testing.expectEqual(Result.success, terminal_c.set(t, .clipboard_read, @ptrCast(&S.clipboardRead)));
    try testing.expectEqual(Result.success, terminal_paste(t, &req, &written));
    try testing.expect(written);
    try testing.expectEqual(@as(usize, 1), S.write_count);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, S.writtenSlice(), "\x1b]5522;"));
    try testing.expect(std.mem.startsWith(u8, S.writtenSlice(), "\x1b]5522;type=read:status=OK:loc=primary:pw="));
    try testing.expect(std.mem.indexOf(u8, S.writtenSlice(), "secret") == null);
    try testing.expect(std.mem.indexOf(u8, S.writtenSlice(), ";dGV4dC9wbGFpbiBpbWFnZS9wbmcK\x1b\\") != null);
    try testing.expectEqual(@as(usize, 0), contents.reads[0]);
    try testing.expectEqual(@as(usize, 0), contents.reads[1]);

    // The program's read with the event password is granted once.
    const ok_prefix = "\x1b]5522;type=read:status=OK:loc=primary:pw=";
    const pw_end = std.mem.indexOfPos(u8, S.writtenSlice(), ok_prefix.len, "\x1b\\").?;
    var read_buf: [256]u8 = undefined;
    const read = try std.fmt.bufPrint(
        &read_buf,
        "\x1b]5522;type=read:pw={s}:name=UGFzdGUgZXZlbnQ=;dGV4dC9wbGFpbg==\x1b\\",
        .{S.writtenSlice()[ok_prefix.len..pw_end]},
    );
    S.reset();
    terminal_c.vt_write(t, read.ptr, read.len);
    try testing.expectEqual(@as(usize, 1), S.read_count);
    try testing.expect(S.last_read_granted);
    try testing.expect(std.mem.indexOf(u8, S.writtenSlice(), ";R2hvc3R0eQ==\x1b\\") != null);

    S.reset();
    terminal_c.vt_write(t, read.ptr, read.len);
    try testing.expectEqual(@as(usize, 1), S.read_count);
    try testing.expect(!S.last_read_granted);

    // Text sources never become events.
    S.reset();
    var ime = req;
    ime.source = .text;
    try testing.expectEqual(Result.success, terminal_paste(t, &ime, &written));
    try testing.expect(written);
    try testing.expectEqualStrings("secret", S.writtenSlice());
}
