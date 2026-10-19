//! C byte-stream callbacks and adapters for `std.Io`.
//!
//! The public callbacks deliberately expose a smaller contract than Zig's I/O
//! interfaces: reads are synchronous progress/EOF/error, and writes accept an
//! entire slice or fail. These adapters translate that contract while keeping
//! enough state to map failures back to distinct C result codes.

const std = @import("std");
const assert = std.debug.assert;
const lib = @import("../lib.zig");

/// C: GhosttyReaderFn
pub const ReaderFn = *const fn (
    userdata: ?*anyopaque,
    buffer: [*]u8,
    capacity: usize,
    out_read: *usize,
) callconv(lib.calling_conv) bool;

/// C: GhosttyWriterFn
pub const WriterFn = *const fn (
    userdata: ?*anyopaque,
    data: [*]const u8,
    len: usize,
) callconv(lib.calling_conv) bool;

/// C: GhosttyReader
pub const Reader = extern struct {
    read: ?ReaderFn = null,
    userdata: ?*anyopaque = null,

    pub fn valid(self: Reader) bool {
        return self.read != null;
    }
};

/// C: GhosttyWriter
pub const Writer = extern struct {
    write: ?WriterFn = null,
    userdata: ?*anyopaque = null,

    pub fn valid(self: Writer) bool {
        return self.write != null;
    }
};

/// C: GhosttyMimeReaderFn
pub const MimeReaderFn = *const fn (
    userdata: ?*anyopaque,
    mime: lib.String,
    writer: Writer,
) callconv(lib.calling_conv) bool;

/// C: GhosttyMimeReader
pub const MimeReader = extern struct {
    read: ?MimeReaderFn = null,
    userdata: ?*anyopaque = null,

    pub fn valid(self: MimeReader) bool {
        return self.read != null;
    }
};

/// Adapts a `GhosttyReader` to `std.Io.Reader`.
///
/// The adapter must have a stable address while `interface` is in use. Its
/// interface starts unbuffered so `init` can safely return it by value. A
/// one-byte buffer is attached lazily when an operation such as `peekByte`
/// requires buffering. This also prevents reads beyond a requested framing
/// boundary.
pub const ReaderAdapter = struct {
    /// Copy of the C callback pair. The pointed-to userdata remains borrowed.
    source: Reader,

    /// Zig-facing interface. Its vtable recovers this enclosing adapter with
    /// `@fieldParentPtr`, which is why the adapter's address must remain stable.
    interface: std.Io.Reader,

    /// Bytes successfully obtained from the callback.
    offset: usize = 0,

    /// The callback returned false. This distinguishes an I/O failure from
    /// the callback returning true with zero bytes at end-of-file.
    callback_failed: bool = false,

    /// The callback was NULL, returned too many bytes, or overflowed offset.
    invalid_read: bool = false,

    /// The callback returned true with zero bytes. EOF is permanent.
    eof: bool = false,

    /// `std.Io.Reader` needs backing storage for `peekByte`. One byte is
    /// intentional: it satisfies that operation without allowing the adapter
    /// to pull a second byte across a snapshot checkpoint or FINISH boundary.
    peek_buffer: [1]u8 = undefined,

    /// Scratch space used only when the destination writer has no writable
    /// buffer of its own. 4 KiB amortizes callback overhead for streaming
    /// operations while keeping every adapter's fixed allocation modest. The
    /// caller's `limit` always truncates this slice, so the size cannot cause
    /// framing read-ahead.
    transfer_buffer: [4096]u8 = undefined,

    pub fn init(source: Reader) ReaderAdapter {
        return .{
            .source = source,
            .interface = .{
                .vtable = &.{
                    .stream = stream,
                    .rebase = rebase,
                },
                // `rebase` attaches peek_buffer after the adapter reaches its
                // stable destination address.
                .buffer = &.{},
                .seek = 0,
                .end = 0,
            },
        };
    }

    pub fn reader(self: *ReaderAdapter) *std.Io.Reader {
        // Calling this only after the adapter reaches its final address makes
        // the parent-pointer recovery in `stream` and `rebase` valid.
        return &self.interface;
    }

    /// Perform exactly one C callback invocation into caller-selected storage.
    /// This is the single place that interprets the public callback contract.
    fn readInto(self: *ReaderAdapter, destination: []u8) std.Io.Reader.Error!usize {
        assert(destination.len > 0);

        // Failure and EOF are sticky. In particular, a callback that reports
        // EOF is never polled again because the C API defines it as permanent.
        if (self.callback_failed or self.invalid_read) return error.ReadFailed;
        if (self.eof) return error.EndOfStream;

        // A missing callback is an invalid C value rather than external I/O
        // failure, so record it separately for the public result mapper.
        const read_fn = self.source.read orelse {
            self.invalid_read = true;
            return error.ReadFailed;
        };

        // Initialize this ourselves: a callback returning false is not
        // required to initialize out_read.
        var read_len: usize = 0;
        if (!read_fn(
            self.source.userdata,
            destination.ptr,
            destination.len,
            &read_len,
        )) {
            self.callback_failed = true;
            return error.ReadFailed;
        }

        // Treat a callback that violates the capacity contract as an invalid
        // reader without constructing an out-of-bounds slice.
        if (read_len > destination.len) {
            self.invalid_read = true;
            return error.ReadFailed;
        }
        // Successful zero-length reads are the C representation of EOF.
        if (read_len == 0) {
            self.eof = true;
            return error.EndOfStream;
        }

        // Offset counts only bytes actually supplied by successful callbacks.
        // Saturating or wrapping would make SOURCE_OFFSET untrustworthy.
        self.offset = std.math.add(usize, self.offset, read_len) catch {
            self.invalid_read = true;
            return error.ReadFailed;
        };
        return read_len;
    }

    /// `stream` is the fundamental read primitive in `std.Io.Reader`'s
    /// vtable. It moves at most `limit` bytes from the C source to the Zig
    /// writer and reports the number transferred. Higher-level operations
    /// such as `readSliceAll` and `peekByte` are implemented in terms of it.
    fn stream(
        reader_: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        // A zero limit is a successful no-op and must not invoke user code.
        if (limit == .nothing) return 0;

        // The std.Io callback receives only the embedded interface pointer.
        // Recover the adapter to reach the C callback and accounting flags.
        const self: *ReaderAdapter = @alignCast(@fieldParentPtr(
            "interface",
            reader_,
        ));

        // Use the destination's storage directly when possible. This is the
        // normal path for readSlice operations and for filling peek_buffer.
        const direct = limit.slice(writer.unusedCapacitySlice());
        if (direct.len > 0) {
            const read_len = try self.readInto(direct);
            // `readInto` initialized these bytes outside the Writer API, so
            // explicitly publish them to the destination.
            writer.advance(read_len);
            return read_len;
        }

        // An unbuffered Writer has no direct destination storage. Read into
        // bounded adapter storage and then let its drain implementation take
        // ownership of the complete slice.
        const transfer = limit.slice(&self.transfer_buffer);
        assert(transfer.len > 0);
        const read_len = try self.readInto(transfer);
        // writeAll either transfers this complete callback result or reports
        // failure; returning a partial count would violate stream's contract.
        try writer.writeAll(transfer[0..read_len]);
        return read_len;
    }

    /// Give buffered reader operations contiguous storage on first demand.
    /// Initialization cannot point at `peek_buffer` because `init` returns the
    /// adapter by value and its final address is not known until afterward.
    fn rebase(
        reader_: *std.Io.Reader,
        capacity: usize,
    ) std.Io.Reader.RebaseError!void {
        const self: *ReaderAdapter = @alignCast(@fieldParentPtr(
            "interface",
            reader_,
        ));

        if (reader_.buffer.len == 0) {
            // No operation could have buffered bytes before storage existed.
            assert(reader_.seek == 0);
            assert(reader_.end == 0);
            reader_.buffer = &self.peek_buffer;
        }

        // Like other std.Io.Reader implementations, contiguous peek capacity
        // is limited by the reader's declared buffer capacity.
        assert(capacity <= reader_.buffer.len);
        // Avoid the default memmove when the unread tail already has room.
        if (reader_.buffer.len - reader_.seek >= capacity) return;
        return std.Io.Reader.defaultRebase(reader_, capacity);
    }
};

/// Adapts a `GhosttyWriter` to a `std.Io.Writer`.
///
/// The adapter may be given a buffer via `initBuffered` so that the many
/// small writes typical of streaming producers (e.g. the formatter) are
/// batched into far fewer C callback invocations. A buffered adapter's owner
/// must call `flush` on the interface before reporting success so that the
/// public contract holds: success means the C callback has already accepted
/// every byte.
pub const WriterAdapter = struct {
    /// Copy of the C callback pair. The pointed-to userdata remains borrowed.
    destination: Writer,

    /// Zig-facing interface whose drain vtable points back to this adapter.
    interface: std.Io.Writer,

    /// Bytes accepted by successful callback invocations. Buffered bytes are
    /// counted only once a drain or flush hands them to the callback.
    offset: usize = 0,

    /// The callback returned false.
    callback_failed: bool = false,

    /// The callback was NULL or offset accounting overflowed.
    invalid_write: bool = false,

    /// The buffer length used by the C API entry points that stream through
    /// a callback. 4 KiB amortizes callback overhead while keeping every
    /// adapter's stack footprint modest, mirroring ReaderAdapter's
    /// transfer_buffer sizing.
    pub const recommended_buffer_len = 4096;

    /// An unbuffered adapter: every Zig write reaches the callback
    /// immediately and no flush is required before returning.
    pub fn init(destination: Writer) WriterAdapter {
        return initBuffered(destination, &.{});
    }

    /// A buffered adapter. The buffer must outlive the adapter and remain
    /// at a stable address (it is referenced, not copied). The owner must
    /// flush the interface before treating the operation as successful.
    pub fn initBuffered(destination: Writer, buffer: []u8) WriterAdapter {
        return .{
            .destination = destination,
            .interface = .{
                .vtable = &.{ .drain = drain },
                .buffer = buffer,
                .end = 0,
            },
        };
    }

    pub fn writer(self: *WriterAdapter) *std.Io.Writer {
        // As with ReaderAdapter, the returned interface borrows this stable
        // enclosing address for parent-pointer recovery in the vtable.
        return &self.interface;
    }

    /// Submit one ordinary slice through the all-or-nothing C write callback.
    fn writeAll(self: *WriterAdapter, data: []const u8) std.Io.Writer.Error!void {
        // Empty writes carry no information and should not call foreign code.
        if (data.len == 0) return;

        // Make failures sticky so a higher-level Zig retry cannot produce a
        // misleading second callback after the output is already partial.
        if (self.callback_failed or self.invalid_write) return error.WriteFailed;

        // Missing callbacks are invalid arguments; false callback returns are
        // external I/O errors. Preserve that distinction for the C wrapper.
        const write_fn = self.destination.write orelse {
            self.invalid_write = true;
            return error.WriteFailed;
        };
        if (!write_fn(self.destination.userdata, data.ptr, data.len)) {
            self.callback_failed = true;
            return error.WriteFailed;
        }

        // Count bytes only after the callback accepts the complete slice.
        self.offset = std.math.add(usize, self.offset, data.len) catch {
            self.invalid_write = true;
            return error.WriteFailed;
        };
    }

    /// Write one slice, batching through the interface buffer when one is
    /// attached. Slices that fit are parked in the buffer (a later drain or
    /// flush hands them to the callback); anything larger goes to the
    /// callback directly after the buffer is emptied to preserve ordering.
    fn writeSlice(
        self: *WriterAdapter,
        writer_: *std.Io.Writer,
        slice: []const u8,
    ) std.Io.Writer.Error!void {
        const buffer = writer_.buffer;
        if (slice.len <= buffer.len - writer_.end) {
            @memcpy(buffer[writer_.end..][0..slice.len], slice);
            writer_.end += slice.len;
            return;
        }

        if (writer_.end > 0) {
            try self.writeAll(buffer[0..writer_.end]);
            writer_.end = 0;
        }

        if (slice.len <= buffer.len) {
            @memcpy(buffer[0..slice.len], slice);
            writer_.end = slice.len;
        } else {
            try self.writeAll(slice);
        }
    }

    /// Implement the sole primitive required by a std.Io.Writer.
    ///
    /// Zig represents a vector write as ordinary slices followed by the last
    /// slice repeated `splat` times. The C callback has no vector form, so
    /// this method expands that representation, batching through the
    /// interface buffer when one is attached, and returns the total logical
    /// byte count consumed from `data`. Bytes parked in the buffer count as
    /// consumed; `std.Io.Writer.flush` drains them via this same method.
    fn drain(
        writer_: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        assert(data.len > 0); // The final element is always the splat pattern.

        // The vtable receives the embedded Writer rather than our adapter.
        const self: *WriterAdapter = @alignCast(@fieldParentPtr(
            "interface",
            writer_,
        ));

        // Buffered bytes must reach the destination before any of `data`.
        if (writer_.end > 0) {
            try self.writeAll(writer_.buffer[0..writer_.end]);
            writer_.end = 0;
        }

        var consumed: usize = 0;
        // Every element except the last is written exactly once.
        for (data[0 .. data.len - 1]) |slice| {
            try self.writeSlice(writer_, slice);
            consumed = std.math.add(usize, consumed, slice.len) catch {
                self.invalid_write = true;
                return error.WriteFailed;
            };
        }

        // std.Io uses the final element as a compact repeated pattern. A
        // splat of zero means the final element is not part of this write.
        const pattern = data[data.len - 1];
        if (pattern.len == 1 and writer_.buffer.len > 0) {
            // Single-byte splats (e.g. runs of blank cells) are memset
            // into the buffer in bulk rather than repeated one write at
            // a time.
            const buffer = writer_.buffer;
            var remaining = splat;
            while (remaining > 0) {
                if (writer_.end == buffer.len) {
                    try self.writeAll(buffer);
                    writer_.end = 0;
                }
                const n = @min(remaining, buffer.len - writer_.end);
                @memset(buffer[writer_.end..][0..n], pattern[0]);
                writer_.end += n;
                remaining -= n;
            }
            consumed = std.math.add(usize, consumed, splat) catch {
                self.invalid_write = true;
                return error.WriteFailed;
            };
        } else for (0..splat) |_| {
            try self.writeSlice(writer_, pattern);
            consumed = std.math.add(usize, consumed, pattern.len) catch {
                self.invalid_write = true;
                return error.WriteFailed;
            };
        }
        return consumed;
    }
};

test "C reader and writer layouts keep callback first" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Reader, "read"));
    try std.testing.expectEqual(@sizeOf(?ReaderFn), @offsetOf(Reader, "userdata"));
    try std.testing.expectEqual(@sizeOf(?ReaderFn) + @sizeOf(?*anyopaque), @sizeOf(Reader));

    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Writer, "write"));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(MimeReader, "read"));
    try std.testing.expectEqual(@sizeOf(?MimeReaderFn), @offsetOf(MimeReader, "userdata"));
    try std.testing.expectEqual(@sizeOf(?WriterFn), @offsetOf(Writer, "userdata"));
    try std.testing.expectEqual(@sizeOf(?WriterFn) + @sizeOf(?*anyopaque), @sizeOf(Writer));
}

test "ReaderAdapter supports short reads and permanent EOF" {
    const Context = struct {
        data: []const u8,
        offset: usize = 0,
        calls: usize = 0,

        fn read(
            userdata: ?*anyopaque,
            buffer: [*]u8,
            capacity: usize,
            out_read: *usize,
        ) callconv(lib.calling_conv) bool {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.calls += 1;
            const remaining = self.data[self.offset..];
            const len = @min(remaining.len, capacity, 2);
            @memcpy(buffer[0..len], remaining[0..len]);
            self.offset += len;
            out_read.* = len;
            return true;
        }
    };

    var context: Context = .{ .data = "abcdef" };
    var adapter: ReaderAdapter = .init(.{
        .read = &Context.read,
        .userdata = &context,
    });

    var actual: [6]u8 = undefined;
    try adapter.interface.readSliceAll(&actual);
    try std.testing.expectEqualStrings("abcdef", &actual);
    try std.testing.expectEqual(@as(usize, 6), adapter.offset);
    try std.testing.expect(!adapter.eof);

    try std.testing.expectError(error.EndOfStream, adapter.interface.takeByte());
    try std.testing.expect(adapter.eof);
    try std.testing.expect(!adapter.callback_failed);

    const calls_at_eof = context.calls;
    try std.testing.expectError(error.EndOfStream, adapter.interface.takeByte());
    try std.testing.expectEqual(calls_at_eof, context.calls);
}

test "ReaderAdapter peek reads only the requested byte" {
    const Context = struct {
        data: []const u8,
        offset: usize = 0,
        last_capacity: usize = 0,

        fn read(
            userdata: ?*anyopaque,
            buffer: [*]u8,
            capacity: usize,
            out_read: *usize,
        ) callconv(lib.calling_conv) bool {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.last_capacity = capacity;
            const remaining = self.data[self.offset..];
            const len = @min(remaining.len, capacity);
            @memcpy(buffer[0..len], remaining[0..len]);
            self.offset += len;
            out_read.* = len;
            return true;
        }
    };

    var context: Context = .{ .data = "ab" };
    var adapter: ReaderAdapter = .init(.{
        .read = &Context.read,
        .userdata = &context,
    });

    try std.testing.expectEqual(@as(u8, 'a'), try adapter.interface.peekByte());
    try std.testing.expectEqual(@as(usize, 1), context.last_capacity);
    try std.testing.expectEqual(@as(usize, 1), adapter.offset);
    try std.testing.expectEqual(@as(u8, 'a'), try adapter.interface.takeByte());
    try std.testing.expectEqual(@as(usize, 1), adapter.offset);
}

test "ReaderAdapter distinguishes callback failure and invalid length" {
    const Failing = struct {
        fn read(
            _: ?*anyopaque,
            _: [*]u8,
            _: usize,
            _: *usize,
        ) callconv(lib.calling_conv) bool {
            return false;
        }
    };
    var failing: ReaderAdapter = .init(.{ .read = &Failing.read });
    try std.testing.expectError(error.ReadFailed, failing.interface.takeByte());
    try std.testing.expect(failing.callback_failed);
    try std.testing.expect(!failing.eof);
    try std.testing.expect(!failing.invalid_read);

    const Oversized = struct {
        fn read(
            _: ?*anyopaque,
            _: [*]u8,
            capacity: usize,
            out_read: *usize,
        ) callconv(lib.calling_conv) bool {
            out_read.* = capacity + 1;
            return true;
        }
    };
    var oversized: ReaderAdapter = .init(.{ .read = &Oversized.read });
    try std.testing.expectError(error.ReadFailed, oversized.interface.takeByte());
    try std.testing.expect(!oversized.callback_failed);
    try std.testing.expect(!oversized.eof);
    try std.testing.expect(oversized.invalid_read);
}

test "ReaderAdapter rejects a null callback" {
    var adapter: ReaderAdapter = .init(.{});
    try std.testing.expectError(error.ReadFailed, adapter.interface.takeByte());
    try std.testing.expect(adapter.invalid_read);
    try std.testing.expect(!adapter.callback_failed);
}

test "WriterAdapter writes vectors and splats" {
    const Context = struct {
        data: [32]u8 = undefined,
        len: usize = 0,

        fn write(
            userdata: ?*anyopaque,
            data: [*]const u8,
            len: usize,
        ) callconv(lib.calling_conv) bool {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            @memcpy(self.data[self.len..][0..len], data[0..len]);
            self.len += len;
            return true;
        }
    };

    var context: Context = .{};
    var adapter: WriterAdapter = .init(.{
        .write = &Context.write,
        .userdata = &context,
    });

    var vectors: [2][]const u8 = .{ "ab", "cd" };
    try adapter.interface.writeVecAll(&vectors);
    var repeated: [1][]const u8 = .{"!"};
    try adapter.interface.writeSplatAll(&repeated, 2);

    try std.testing.expectEqualStrings("abcd!!", context.data[0..context.len]);
    try std.testing.expectEqual(@as(usize, 6), adapter.offset);
    try std.testing.expect(!adapter.callback_failed);
}

test "WriterAdapter buffered batches small writes" {
    const Context = struct {
        data: [256]u8 = undefined,
        len: usize = 0,
        calls: usize = 0,

        fn write(
            userdata: ?*anyopaque,
            data: [*]const u8,
            len: usize,
        ) callconv(lib.calling_conv) bool {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            @memcpy(self.data[self.len..][0..len], data[0..len]);
            self.len += len;
            self.calls += 1;
            return true;
        }
    };

    var context: Context = .{};
    var buffer: [64]u8 = undefined;
    var adapter: WriterAdapter = .initBuffered(.{
        .write = &Context.write,
        .userdata = &context,
    }, &buffer);

    // Many small writes fit in the buffer: no callback yet.
    for (0..16) |_| try adapter.interface.writeAll("ab");
    try std.testing.expectEqual(@as(usize, 0), context.calls);

    // Flush delivers everything in a single call.
    try adapter.interface.flush();
    try std.testing.expectEqual(@as(usize, 1), context.calls);
    try std.testing.expectEqualStrings(
        "ab" ** 16,
        context.data[0..context.len],
    );
    try std.testing.expectEqual(@as(usize, 32), adapter.offset);
}

test "WriterAdapter buffered splats and large writes" {
    const Context = struct {
        data: [256]u8 = undefined,
        len: usize = 0,
        calls: usize = 0,

        fn write(
            userdata: ?*anyopaque,
            data: [*]const u8,
            len: usize,
        ) callconv(lib.calling_conv) bool {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            @memcpy(self.data[self.len..][0..len], data[0..len]);
            self.len += len;
            self.calls += 1;
            return true;
        }
    };

    var context: Context = .{};
    var buffer: [16]u8 = undefined;
    var adapter: WriterAdapter = .initBuffered(.{
        .write = &Context.write,
        .userdata = &context,
    }, &buffer);

    // A splat larger than the buffer is chunked, not one call per byte.
    try adapter.interface.splatByteAll(' ', 40);
    // A write larger than the buffer flushes and goes to the callback
    // directly.
    try adapter.interface.writeAll("0123456789abcdef0"); // 17 > 16
    try adapter.interface.writeAll("xy");
    try adapter.interface.flush();

    try std.testing.expectEqualStrings(
        " " ** 40 ++ "0123456789abcdef0" ++ "xy",
        context.data[0..context.len],
    );
    try std.testing.expectEqual(
        @as(usize, context.len),
        adapter.offset,
    );
    // Chunked delivery: far fewer calls than bytes.
    try std.testing.expect(context.calls <= 6);
}

test "WriterAdapter makes callback failure sticky" {
    const Context = struct {
        calls: usize = 0,

        fn write(
            userdata: ?*anyopaque,
            _: [*]const u8,
            _: usize,
        ) callconv(lib.calling_conv) bool {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.calls += 1;
            return false;
        }
    };

    var context: Context = .{};
    var adapter: WriterAdapter = .init(.{
        .write = &Context.write,
        .userdata = &context,
    });
    try std.testing.expectError(error.WriteFailed, adapter.interface.writeAll("x"));
    try std.testing.expect(adapter.callback_failed);
    try std.testing.expectEqual(@as(usize, 0), adapter.offset);

    try std.testing.expectError(error.WriteFailed, adapter.interface.writeAll("y"));
    try std.testing.expectEqual(@as(usize, 1), context.calls);
}

test "WriterAdapter rejects a null callback" {
    var adapter: WriterAdapter = .init(.{});
    try std.testing.expectError(error.WriteFailed, adapter.interface.writeAll("x"));
    try std.testing.expect(adapter.invalid_write);
    try std.testing.expect(!adapter.callback_failed);
}

test "ReaderAdapter streams into an unbuffered WriterAdapter" {
    const ReadContext = struct {
        data: []const u8,
        offset: usize = 0,

        fn read(
            userdata: ?*anyopaque,
            buffer: [*]u8,
            capacity: usize,
            out_read: *usize,
        ) callconv(lib.calling_conv) bool {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            const remaining = self.data[self.offset..];
            const len = @min(remaining.len, capacity);
            @memcpy(buffer[0..len], remaining[0..len]);
            self.offset += len;
            out_read.* = len;
            return true;
        }
    };
    const WriteContext = struct {
        data: [8]u8 = undefined,
        len: usize = 0,

        fn write(
            userdata: ?*anyopaque,
            data: [*]const u8,
            len: usize,
        ) callconv(lib.calling_conv) bool {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            @memcpy(self.data[self.len..][0..len], data[0..len]);
            self.len += len;
            return true;
        }
    };

    var read_context: ReadContext = .{ .data = "stream" };
    var reader: ReaderAdapter = .init(.{
        .read = &ReadContext.read,
        .userdata = &read_context,
    });
    var write_context: WriteContext = .{};
    var writer: WriterAdapter = .init(.{
        .write = &WriteContext.write,
        .userdata = &write_context,
    });

    try reader.interface.streamExact(&writer.interface, "stream".len);
    try std.testing.expectEqualStrings(
        "stream",
        write_context.data[0..write_context.len],
    );
    try std.testing.expectEqual(@as(usize, "stream".len), reader.offset);
    try std.testing.expectEqual(@as(usize, "stream".len), writer.offset);
}
