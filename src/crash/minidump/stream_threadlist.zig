const std = @import("std");
const assert = std.debug.assert;
const external = @import("external.zig");
const readerpkg = @import("reader.zig");
const Reader = readerpkg.Reader;
const ReadError = readerpkg.ReadError;

const log = std.log.scoped(.minidump_stream);

/// This is the list of threads from the process.
///
/// This is the Reader implementation. You usually do not use this directly.
/// Instead, use Reader(T).ThreadList which will get you the same thing.
///
/// ThreadList is stream type 0x3.
/// StreamReader is the Reader(T).StreamReader type.
pub fn ThreadListReader(comptime R: type) type {
    return struct {
        const Self = @This();

        /// The number of threads in the list.
        count: u32,

        /// The rva to the first thread in the list.
        rva: u32,

        /// Source data and endianness so we can read.
        source: R.Source,
        endian: std.builtin.Endian,

        pub fn init(r: *R.StreamReader) !Self {
            assert(r.directory.stream_type == 0x3);
            try r.seekToPayload();
            const reader = r.source.reader();

            // Our count is always a u32 in the header.
            const count = try reader.readInt(u32, r.endian);

            // Determine if we have padding in our header. It is possible
            // for there to be padding if the list header was written by
            // a 32-bit process but is being read on a 64-bit process.
            const padding = padding: {
                const maybe_size = @sizeOf(u32) + (@sizeOf(external.Thread) * count);
                switch (std.math.order(maybe_size, r.directory.location.data_size)) {
                    // It should never be larger than what the directory says.
                    .gt => return ReadError.StreamSizeMismatch,

                    // If the sizes match exactly we're good.
                    .eq => break :padding 0,

                    .lt => {
                        const padding = r.directory.location.data_size - maybe_size;
                        if (padding != 4) return ReadError.StreamSizeMismatch;
                        break :padding padding;
                    },
                }
            };

            // Rva is the location of the first thread in the list.
            const rva = r.directory.location.rva + @as(u32, @sizeOf(u32)) + padding;

            return .{
                .count = count,
                .rva = rva,
                .source = r.source,
                .endian = r.endian,
            };
        }

        /// Get the thread entry for the given index.
        ///
        /// Index is asserted to be less than count.
        pub fn thread(self: *const Self, i: usize) !external.Thread {
            assert(i < self.count);

            // Seek to the thread
            const offset: u32 = @intCast(@sizeOf(external.Thread) * i);
            const rva: u32 = self.rva + offset;
            try self.source.seekableStream().seekTo(rva);

            // Read the thread
            return try self.source.reader().readStructEndian(
                external.Thread,
                self.endian,
            );
        }
    };
}

test "minidump: threadlist" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var fbs = std.Io.fixedBufferStream(@embedFile("../testdata/macos.dmp"));
    const R = Reader(*@TypeOf(fbs));
    const r = try R.init(&fbs);

    // Get our thread list stream
    const dir = try r.directory(0);
    try testing.expectEqual(3, dir.stream_type);
    var sr = try r.streamReader(dir);

    // Get our rich structure
    const v = try R.ThreadList.init(&sr);
    log.warn("threadlist count={} rva={}", .{ v.count, v.rva });

    try testing.expectEqual(12, v.count);
    for (0..v.count) |i| {
        const t = try v.thread(i);
        log.warn("thread i={} thread={}", .{ i, t });

        // Read our stack memory
        var stack_reader = try r.locationReader(t.stack.memory);
        const bytes = try stack_reader.reader().readAllAlloc(alloc, t.stack.memory.data_size);
        defer alloc.free(bytes);
    }
}
