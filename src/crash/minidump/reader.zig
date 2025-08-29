const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const external = @import("external.zig");
const stream = @import("stream.zig");
const EncodedStream = stream.EncodedStream;

const log = std.log.scoped(.minidump_reader);

/// Possible minidump-specific errors that can occur when reading a minidump.
/// This isn't the full error set since IO errors can also occur depending
/// on the Source type.
pub const ReadError = error{
    InvalidHeader,
    InvalidVersion,
    StreamSizeMismatch,
};

/// Reader creates a new minidump reader for the given source type. The
/// source must have both a "reader()" and "seekableStream()" function.
///
/// Given the format of a minidump file, we must keep the source open and
/// continually access it because the format of the minidump is full of
/// pointers and offsets that we must follow depending on the stream types.
/// Also, since we're not aware of all stream types (in fact its impossible
/// to be aware since custom stream types are allowed), its possible any stream
/// type can define their own pointers and offsets. So, the source must always
/// be available so callers can decode the streams as needed.
pub fn Reader(comptime S: type) type {
    return struct {
        const Self = @This();

        /// The source data.
        source: Source,

        /// The endianness of the minidump file. This is detected by reading
        /// the byte order of the header.
        endian: std.builtin.Endian,

        /// The number of streams within the minidump file. This is read from
        /// the header and stored here so we can quickly access them. Note
        /// the stream types require reading the source; this is an optimization
        /// to avoid any allocations on the reader and the caller can choose
        /// to store them if they want.
        stream_count: u32,
        stream_directory_rva: u32,

        const SourceCallable = switch (@typeInfo(Source)) {
            .pointer => |v| v.child,
            .@"struct" => Source,
            else => @compileError("Source type must be a pointer or struct"),
        };

        const SourceReader = @typeInfo(@TypeOf(SourceCallable.reader)).@"fn".return_type.?;
        const SourceSeeker = @typeInfo(@TypeOf(SourceCallable.seekableStream)).@"fn".return_type.?;

        /// A limited reader for reading data from the source.
        pub const LimitedReader = std.Io.LimitedReader(SourceReader);

        /// The source type for the reader.
        pub const Source = S;

        /// The stream types for reading
        pub const ThreadList = stream.thread_list.ThreadListReader(Self);

        /// The reader type for stream reading. This has some other methods so
        /// you must still call reader() on the result to get the actual
        /// reader to read the data.
        pub const StreamReader = struct {
            source: Source,
            endian: std.builtin.Endian,
            directory: external.Directory,

            /// Should not be accessed directly. This is setup whenever
            /// reader() is called.
            limit_reader: LimitedReader = undefined,

            pub const Reader = LimitedReader.Reader;

            /// Returns a Reader implementation that reads the bytes of the
            /// stream.
            ///
            /// The reader is dependent on the state of Source so any
            /// state-changing operations on Source will invalidate the
            /// reader. For example, making another reader, reading another
            /// stream directory, closing the source, etc.
            pub fn reader(self: *StreamReader) LimitedReader.Reader {
                try self.source.seekableStream().seekTo(self.directory.location.rva);
                self.limit_reader = .{
                    .inner_reader = self.source.reader(),
                    .bytes_left = self.directory.location.data_size,
                };
                return self.limit_reader.reader();
            }

            /// Seeks the source to the location of the directory.
            pub fn seekToPayload(self: *StreamReader) !void {
                try self.source.seekableStream().seekTo(self.directory.location.rva);
            }
        };

        /// Iterator type to read over the streams in the minidump file.
        pub const StreamIterator = struct {
            reader: *const Self,
            i: u32 = 0,

            pub fn next(self: *StreamIterator) !?StreamReader {
                if (self.i >= self.reader.stream_count) return null;
                const dir = try self.reader.directory(self.i);
                self.i += 1;
                return try self.reader.streamReader(dir);
            }
        };

        /// Initialize a reader. The source must remain available for the entire
        /// lifetime of the reader. The reader does not take ownership of the
        /// source so if it has resources that need to be cleaned up, the caller
        /// must do so once the reader is no longer needed.
        pub fn init(source: Source) !Self {
            const header, const endian = try readHeader(Source, source);
            return .{
                .source = source,
                .endian = endian,
                .stream_count = header.stream_count,
                .stream_directory_rva = header.stream_directory_rva,
            };
        }

        /// Return an iterator to read over the streams in the minidump file.
        /// This is very similar to using a simple for loop to stream_count
        /// and calling directory() on each index, but is more idiomatic
        /// Zig.
        pub fn streamIterator(self: *const Self) StreamIterator {
            return .{ .reader = self };
        }

        /// Return a StreamReader for the given directory type. This streams
        /// from the underlying source so the returned reader is only valid
        /// as long as the source is unmodified (i.e. the source is not
        /// closed, the source seek position is not moved, etc.).
        pub fn streamReader(
            self: *const Self,
            dir: external.Directory,
        ) SourceSeeker.SeekError!StreamReader {
            return .{
                .source = self.source,
                .endian = self.endian,
                .directory = dir,
            };
        }

        /// Get the directory entry with the given index.
        ///
        /// Asserts the index is valid (idx < stream_count).
        pub fn directory(self: *const Self, idx: usize) !external.Directory {
            assert(idx < self.stream_count);

            // Seek to the directory.
            const offset: u32 = @intCast(@sizeOf(external.Directory) * idx);
            const rva: u32 = self.stream_directory_rva + offset;
            try self.source.seekableStream().seekTo(rva);

            // Read the directory.
            return try self.source.reader().readStructEndian(
                external.Directory,
                self.endian,
            );
        }

        /// Return a reader for the given location descriptor. This is only
        /// valid until the reader source is modified in some way.
        pub fn locationReader(
            self: *const Self,
            loc: external.LocationDescriptor,
        ) !LimitedReader {
            try self.source.seekableStream().seekTo(loc.rva);
            return .{
                .inner_reader = self.source.reader(),
                .bytes_left = loc.data_size,
            };
        }
    };
}

/// Reads the header for the minidump file and returns endianness of
/// the file.
fn readHeader(comptime T: type, source: T) !struct {
    external.Header,
    std.builtin.Endian,
} {
    // Start by trying LE.
    var endian: std.builtin.Endian = .little;
    var header = try source.reader().readStructEndian(external.Header, endian);

    // If the signature doesn't match, we assume its BE.
    if (header.signature != external.signature) {
        // Seek back to the start of the file so we can reread.
        try source.seekableStream().seekTo(0);

        // Try BE, if the signature doesn't match, return an error.
        endian = .big;
        header = try source.reader().readStructEndian(external.Header, endian);
        if (header.signature != external.signature) return ReadError.InvalidHeader;
    }

    // "The low-order word is MINIDUMP_VERSION. The high-order word is an
    // internal value that is implementation specific."
    if (header.version.low != external.version) return ReadError.InvalidVersion;

    return .{ header, endian };
}

// Uncomment to dump some debug information for a minidump file.
test "minidump debug" {
    var fbs = std.Io.fixedBufferStream(@embedFile("../testdata/macos.dmp"));
    const r = try Reader(*@TypeOf(fbs)).init(&fbs);
    var it = r.streamIterator();
    while (try it.next()) |s| {
        log.warn("directory i={} dir={}", .{ it.i - 1, s.directory });
    }
}

test "minidump read" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var fbs = std.Io.fixedBufferStream(@embedFile("../testdata/macos.dmp"));
    const r = try Reader(*@TypeOf(fbs)).init(&fbs);
    try testing.expectEqual(std.builtin.Endian.little, r.endian);
    try testing.expectEqual(7, r.stream_count);
    {
        const dir = try r.directory(0);
        try testing.expectEqual(3, dir.stream_type);
        try testing.expectEqual(584, dir.location.data_size);

        var bytes = std.ArrayList(u8).init(alloc);
        defer bytes.deinit();
        var sr = try r.streamReader(dir);
        try sr.reader().readAllArrayList(&bytes, std.math.maxInt(usize));
        try testing.expectEqual(584, bytes.items.len);
    }
}
