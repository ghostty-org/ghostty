const std = @import("std");
const builtin = @import("builtin");
const assert = @import("quirks").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const posix = std.posix;

const fastmem = @import("fastmem");
const command = @import("graphics_command.zig");
const PageList = @import("../PageList.zig");
const sys = @import("../sys.zig");
const LimitedAllocator = @import("datastruct").LimitedAllocator;

const log = std.log.scoped(.kitty_gfx);

/// Maximum width or height of an image. Taken directly from Kitty.
const max_dimension = 10000;

/// Maximum size in bytes, taken from Kitty.
const max_size = 400 * 1024 * 1024; // 400MB

/// An image that is still being loaded. The image should be initialized
/// using init on the first chunk and then addData for each subsequent
/// chunk. Once all chunks have been added, complete should be called
/// to finalize the image.
pub const LoadingImage = struct {
    /// The in-progress image. The first chunk must have all the metadata
    /// so this comes from that initially.
    image: Image,

    /// The data that is being built up.
    data: std.ArrayListUnmanaged(u8) = .empty,

    /// This is non-null when a transmit and display command is given
    /// so that we display the image after it is fully loaded.
    display: ?command.Display = null,

    /// Quiet is the quiet settings for the initial load command. This is
    /// used if q isn't set on subsequent chunks.
    quiet: command.Command.Quiet,

    /// The temporary directory for file transmission (null means that
    /// temporary directory transmission is disabled).
    temporary_directory: ?[]const u8,

    /// The limits of the Kitty Graphics protocol we should allow.
    ///
    /// This can be used to restrict the type of images and other
    /// parameters for resource or security reasons. Note that depending
    /// on how libghostty is compiled, some of these may be fully unsupported
    /// and ignored (e.g. "file" on wasm32-freestanding).
    pub const Limits = struct {
        file: bool,
        temporary_file: union(enum) {
            enabled: struct {
                /// The directory to expect temporary files in.
                directory: []const u8,
            },
            disabled: void,
        },
        shared_memory: bool,

        /// Enables all filesystem-related image transmission mediums. `path`
        /// is the temporary directory to expect files in when files are
        /// transmitted using said medium.
        pub fn allWithTempDir(path: []const u8) Limits {
            return .{
                .file = true,
                .temporary_file = .{ .enabled = .{ .directory = path } },
                .shared_memory = true,
            };
        }

        pub const direct: Limits = .{
            .file = false,
            .temporary_file = .disabled,
            .shared_memory = false,
        };
    };

    /// Initialize a chunked immage from the first image transmission.
    /// If this is a multi-chunk image, this should only be the FIRST
    /// chunk.
    pub fn init(
        io: std.Io,
        alloc: Allocator,
        cmd: *const command.Command,
        limits: Limits,
    ) !LoadingImage {
        // Build our initial image from the properties sent via the control.
        // These can be overwritten by the data loading process. For example,
        // PNG loading sets the width/height from the data.
        const t = cmd.transmission().?;
        var result: LoadingImage = .{
            .image = .{
                .id = t.image_id,
                .number = t.image_number,
                .width = t.width,
                .height = t.height,
                .compression = t.compression,
                .format = t.format,
                .metadata = .{ .transient = t.usage.transient },
            },

            .display = cmd.display(),
            .quiet = cmd.quiet,
            .temporary_directory = switch (limits.temporary_file) {
                .enabled => |d| d.directory,
                .disabled => null,
            },
        };

        // Special case for the direct medium, we just add the chunk directly.
        if (t.medium == .direct) {
            try result.addData(alloc, cmd.data);
            return result;
        }

        // Verify our capabilities and limits allow this.
        {
            // Special case if we don't support decoding PNGs and the format
            // is a PNG we can save a lot of memory/effort buffering the
            // data but failing up front.
            if (t.format == .png and
                sys.decode_png == null)
            {
                return error.UnsupportedMedium;
            }

            // Verify the medium is allowed
            switch (t.medium) {
                .direct => unreachable,
                .file => if (!limits.file) return error.UnsupportedMedium,
                .temporary_file => if (limits.temporary_file == .disabled) return error.UnsupportedMedium,
                .shared_memory => if (!limits.shared_memory) return error.UnsupportedMedium,
            }
        }

        // Otherwise, the payload data is guaranteed to be a path.

        if (comptime builtin.os.tag != .windows) {
            if (std.mem.indexOfScalar(u8, cmd.data, 0) != null) {
                // POSIX paths cannot contain internal nulls.
                log.warn("invalid image path: BadPathName", .{});
                return error.InvalidData;
            }
        }

        // Depending on the medium, load the data from the path.
        switch (t.medium) {
            .direct => unreachable, // handled above
            .file => try result.readFile(.file, io, alloc, t, cmd.data),
            .temporary_file => try result.readFile(.temporary_file, io, alloc, t, cmd.data),
            .shared_memory => try result.readSharedMemory(io, alloc, t, cmd.data),
        }

        return result;
    }

    /// Reads the data from a shared memory segment.
    fn readSharedMemory(
        self: *LoadingImage,
        io: std.Io,
        alloc: Allocator,
        t: command.Transmission,
        path: []const u8,
    ) !void {
        // android does not support POSIX shared memory.
        // windows is currently unsupported, does it support shm?
        if (comptime builtin.abi.isAndroid() or builtin.target.os.tag == .windows) {
            return error.UnsupportedMedium;
        }

        // libc is required for shm_open
        if (comptime !builtin.link_libc) {
            return error.UnsupportedMedium;
        }

        // Since we're only supporting posix then max_path_bytes should
        // be enough to stack allocate the path.
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const pathz = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return error.InvalidData;

        const fd = std.c.shm_open(pathz, @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })), @as(u16, 0));
        switch (std.posix.errno(fd)) {
            .SUCCESS => {},
            else => |err| {
                log.warn("unable to open shared memory {s}: {}", .{ path, err });
                return error.InvalidData;
            },
        }
        const file: std.Io.File = .{
            .handle = fd,
            .flags = .{ .nonblocking = false },
        };

        defer file.close(io);
        defer _ = std.c.shm_unlink(pathz);

        // The size from stat on may be larger than our expected size because
        // shared memory has to be a multiple of the page size.
        const stat_size: usize = stat: {
            const stat = file.stat(io) catch |err| {
                log.warn("unable to fstat shared memory {s}: {}", .{ path, err });
                return error.InvalidData;
            };
            if (stat.size <= 0) return error.InvalidData;
            break :stat std.math.cast(usize, stat.size) orelse
                return error.InvalidData;
        };

        // Get the memory range we'll read. Validate it to make sure
        // it doesn't overflow.
        const range = try self.sharedMemoryRange(t, stat_size);

        const map = std.posix.mmap(
            null,
            stat_size, // mmap always uses the stat size
            .{ .READ = true },
            std.c.MAP{ .TYPE = .SHARED },
            fd,
            0,
        ) catch |err| {
            log.warn("unable to mmap shared memory {s}: {}", .{ path, err });
            return error.InvalidData;
        };
        defer std.posix.munmap(map);

        assert(self.data.items.len == 0);
        try self.data.appendSlice(alloc, map[range.start..range.end]);
    }

    const SharedMemoryRange = struct {
        start: usize,
        end: usize,
    };

    /// Returns the byte range to copy from a shared memory object.
    fn sharedMemoryRange(
        self: *const LoadingImage,
        t: command.Transmission,
        stat_size: usize,
    ) error{
        InvalidData,
        DimensionsTooLarge,
    }!SharedMemoryRange {
        const expected_size: ?usize = switch (self.image.format) {
            // PNG dimensions come from the decoded data.
            .png => null,

            // Validate before multiplying because protocol dimensions are
            // u32 values and may otherwise overflow in safe builds.
            .gray, .gray_alpha, .rgb, .rgba => size: {
                if (self.image.width > max_dimension or
                    self.image.height > max_dimension)
                {
                    return error.DimensionsTooLarge;
                }

                const bpp: usize = command.Transmission.formatBpp(self.image.format);
                break :size @as(usize, self.image.width) *
                    @as(usize, self.image.height) * bpp;
            },
        };

        // Get our start offset and validate its within the range of
        // the statted data.
        const start = std.math.cast(usize, t.offset) orelse
            return error.InvalidData;
        if (start > stat_size) return error.InvalidData;

        // Validate that our length is within the stat range too.
        const available = stat_size - start;
        const data_size: usize = if (t.size > 0)
            std.math.cast(usize, t.size) orelse return error.InvalidData
        else if (self.image.compression == .none and expected_size != null)
            expected_size.?
        else
            available;
        if (data_size > max_size or data_size > available) {
            return error.InvalidData;
        }

        // data_size <= available guarantees this addition cannot overflow.
        return .{ .start = start, .end = start + data_size };
    }

    /// Reads the data from a temporary file and returns it. This allocates
    /// and does not free any of the data, so the caller must free it.
    ///
    /// This will also delete the temporary file if it is in a safe location.
    fn readFile(
        self: *LoadingImage,
        comptime medium: command.Transmission.Medium,
        io: std.Io,
        alloc: Allocator,
        t: command.Transmission,
        path: []const u8,
    ) !void {
        switch (medium) {
            .file, .temporary_file => {},
            else => @compileError("readFile only supports file and temporary_file"),
        }

        // Open our file right away before we do validation. This avoids
        // TOCTOU issues.
        var file = std.Io.Dir.cwd().openFile(
            io,
            path,
            .{},
        ) catch |err| {
            log.warn("failed to open image file: {}", .{err});
            return error.InvalidData;
        };

        // We'll populate a delete path if this is a temporary file.
        var delete_path: ?[]const u8 = null;
        defer {
            file.close(io);
            if (delete_path) |p| {
                std.Io.Dir.cwd().deleteFile(io, p) catch |err| {
                    log.warn("failed to delete temporary file: {}", .{err});
                };
            }
        }

        // Derive the path from the open handle so the file we validate is the
        // exact file we read. Resolving a path before opening it would allow a
        // cooperating process to swap a symlink or directory entry in between.
        var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs_path = validatedFilePath(
            io,
            file,
            &abs_buf,
        ) catch |err| {
            log.warn("failed to validate image file path: {}", .{err});
            return error.InvalidData;
        };

        // Temporary file logic
        if (medium == .temporary_file) {
            assert(self.temporary_directory != null);
            if (!isPathInTempDir(
                io,
                self.temporary_directory.?,
                abs_path,
            )) return error.TemporaryFileNotInTempDir;
            if (std.mem.indexOf(
                u8,
                abs_path,
                "tty-graphics-protocol",
            ) == null) return error.TemporaryFileNotNamedCorrectly;
            delete_path = abs_path;
        }

        // File must be a regular file
        if (file.stat(io)) |stat| {
            if (stat.kind != .file) {
                log.warn("file is not a regular file kind={}", .{stat.kind});
                return error.InvalidData;
            }
        } else |err| {
            log.warn("failed to stat file: {}", .{err});
            return error.InvalidData;
        }

        var buf: [4096]u8 = undefined;
        var buf_reader = file.reader(io, &buf);
        if (t.offset > 0) {
            buf_reader.seekTo(@intCast(t.offset)) catch |err| {
                log.warn("failed to seek to offset {}: {}", .{ t.offset, err });
                return error.InvalidData;
            };
        }
        const reader = &buf_reader.interface;

        // Read the file
        var managed: std.ArrayList(u8) = .empty;
        errdefer managed.deinit(alloc);
        const size: usize = if (t.size > 0) @min(t.size, max_size) else max_size;
        reader.appendRemaining(alloc, &managed, .limited(size)) catch {
            log.warn("failed to read temporary file: {?}", .{buf_reader.err});
            return error.InvalidData;
        };

        // Set our data
        assert(self.data.items.len == 0);
        self.data = .{ .items = managed.items, .capacity = managed.capacity };
    }

    /// Returns the canonical path of an open file after applying the file
    /// transmission blocklist.
    fn validatedFilePath(io: std.Io, file: std.Io.File, buf: []u8) ![]const u8 {
        const path = buf[0..try file.realPath(io, buf)];

        // This is logic copied directly from Kitty, mostly. This is really
        // rough but it will catch obvious bad actors.
        if (std.mem.startsWith(u8, path, "/proc/") or
            std.mem.startsWith(u8, path, "/sys/") or
            (std.mem.startsWith(u8, path, "/dev/") and
                !std.mem.startsWith(u8, path, "/dev/shm/")))
        {
            return error.InvalidData;
        }

        return path;
    }

    /// Returns true if path appears to be in a temporary directory.
    /// Copies logic from Kitty.
    fn isPathInTempDir(io: std.Io, dir: []const u8, path: []const u8) bool {
        if (isPathInDir("/tmp", path)) return true;
        if (isPathInDir("/dev/shm", path)) return true;
        if (isPathInDir(dir, path)) return true;

        // The temporary dir is sometimes a symlink. On macOS for
        // example /tmp is /private/var/...
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const real_dir = buf[0 .. std.Io.Dir.cwd().realPathFile(
            io,
            dir,
            &buf,
        ) catch return false];
        if (isPathInDir(real_dir, path)) return true;

        return false;
    }

    pub fn deinit(self: *LoadingImage, alloc: Allocator) void {
        self.image.deinit(alloc);
        self.data.deinit(alloc);
    }

    pub fn destroy(self: *LoadingImage, alloc: Allocator) void {
        self.deinit(alloc);
        alloc.destroy(self);
    }

    /// Adds a chunk of data to the image. Use this if the image
    /// is coming in chunks (the "m" parameter in the protocol).
    pub fn addData(self: *LoadingImage, alloc: Allocator, data: []const u8) !void {
        // If no data, skip
        if (data.len == 0) return;

        // If our data would get too big, return an error
        if (self.data.items.len + data.len > max_size) {
            log.warn("image data too large max_size={}", .{max_size});
            return error.InvalidData;
        }

        // Ensure we have enough room to add the data
        // to the end of the ArrayList before doing so.
        try self.data.ensureUnusedCapacity(alloc, data.len);

        const start_i = self.data.items.len;
        self.data.items.len = start_i + data.len;
        fastmem.copy(u8, self.data.items[start_i..], data);
    }

    /// Complete the chunked image, returning a completed image.
    pub fn complete(self: *LoadingImage, alloc: Allocator) !Image {
        const img = &self.image;

        // Decompress the data if it is compressed.
        try self.decompress(alloc);

        // Decode the png if we have to
        if (img.format == .png) try self.decodePng(alloc);

        // Validate our dimensions.
        if (img.width == 0 or img.height == 0) return error.DimensionsRequired;
        if (img.width > max_dimension or img.height > max_dimension) return error.DimensionsTooLarge;

        // Data length must be what we expect
        const bpp = command.Transmission.formatBpp(img.format);
        const expected_len = img.width * img.height * bpp;
        const actual_len = self.data.items.len;
        if (actual_len != expected_len) {
            std.log.warn(
                "unexpected length image id={} width={} height={} bpp={} expected_len={} actual_len={}",
                .{ img.id, img.width, img.height, bpp, expected_len, actual_len },
            );
            return error.InvalidData;
        }

        // Everything looks good, copy the image data over.
        var result = self.image;
        result.data = .{ .complete = try self.data.toOwnedSlice(alloc) };
        errdefer result.deinit(alloc);
        self.image = .{};
        return result;
    }

    /// Debug function to write the data to a file. This is useful for
    /// capturing some test data for unit tests.
    pub fn debugDump(io: std.Io, self: LoadingImage) !void {
        if (comptime builtin.mode != .Debug) @compileError("debugDump in non-debug");

        var buf: [1024]u8 = undefined;
        const filename = try std.fmt.bufPrint(
            &buf,
            "image-{s}-{s}-{d}x{d}-{}.data",
            .{
                @tagName(self.image.format),
                @tagName(self.image.compression),
                self.image.width,
                self.image.height,
                self.image.id,
            },
        );
        const cwd = std.Io.Dir.cwd();
        const f = try cwd.createFile(io, filename, .{});
        defer f.close(io);

        const writer = f.writer();
        try writer.writeAll(self.data.items);
    }

    /// Decompress the data in-place.
    fn decompress(self: *LoadingImage, alloc: Allocator) !void {
        return switch (self.image.compression) {
            .none => {},
            .zlib_deflate => self.decompressZlib(alloc),
        };
    }

    fn decompressZlib(self: *LoadingImage, alloc: Allocator) !void {
        // Open our zlib stream
        var buf: [std.compress.flate.max_window_len]u8 = undefined;
        var reader: std.Io.Reader = .fixed(self.data.items);
        var stream: std.compress.flate.Decompress = .init(&reader, .zlib, &buf);

        // Write it to an array list
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(alloc);
        stream.reader.appendRemaining(alloc, &list, .limited(max_size)) catch {
            log.warn("failed to read decompressed data: {?}", .{stream.err});
            return error.DecompressionFailed;
        };

        // Empty our current data list, take ownership over managed array list
        self.data.deinit(alloc);
        self.data = .{ .items = list.items, .capacity = list.capacity };

        // Make sure we note that our image is no longer compressed
        self.image.compression = .none;
    }

    /// Decode the data as PNG. This will also updated the image dimensions.
    fn decodePng(self: *LoadingImage, alloc: Allocator) !void {
        assert(self.image.format == .png);

        const decode_png_fn = sys.decode_png orelse
            return error.UnsupportedFormat;

        var limited: LimitedAllocator = .init(alloc, max_size);
        const decode_alloc = limited.allocator();
        const result = decode_png_fn(
            decode_alloc,
            self.data.items,
        ) catch |err| switch (err) {
            error.InvalidData => return error.InvalidData,
            error.OutOfMemory => if (limited.limit_exceeded)
                return error.InvalidData
            else
                return error.OutOfMemory,
        };
        defer decode_alloc.free(result.data);

        if (result.data.len > max_size) {
            log.warn("png image too large size={} max_size={}", .{ result.data.len, max_size });
            return error.InvalidData;
        }

        // Replace our data
        self.data.deinit(alloc);
        self.data = .empty;
        try self.data.ensureUnusedCapacity(alloc, result.data.len);
        try self.data.appendSlice(alloc, result.data[0..result.data.len]);

        // Store updated image dimensions
        self.image.width = result.width;
        self.image.height = result.height;
        self.image.format = .rgba;
    }
};

/// Image represents a single image whose metadata is fully known.
///
/// Complete image data is always fully decoded raw pixels: loading inflates
/// any zlib-compressed payload and decodes PNG into RGBA before an image is
/// completed, so `compression` is always `.none` and `format` is never `.png`
/// for a stored image. Pending image data reserves the exact decoded byte
/// length that will be attached later.
pub const Image = struct {
    id: u32 = 0,
    number: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    format: command.Transmission.Format = .rgb,
    compression: command.Transmission.Compression = .none,
    data: Data = .{ .complete = "" },
    metadata: packed struct(u32) {
        /// The image's transient usage hint, used to prioritize eviction.
        transient: bool = false,

        /// Set this if the image was loaded without an ID or number. Such
        /// images must not receive responses even though they currently get
        /// IDs in the public range (which is bad!).
        implicit_id: bool = false,

        /// Number of placements referencing this image.
        placement_count: u30 = 0,
    } = .{},

    /// Unique, monotonically increasing stamp assigned each time an
    /// image is added to (or replaced in) an ImageStorage. A changed
    /// generation for a given image ID means the image contents may
    /// have changed, even if the dimensions and byte length are the
    /// same (e.g. a retransmission of the same ID). Stamps order by
    /// transmission time. Zero means "never stored".
    generation: u64 = 0,

    pub const Error = error{
        InvalidData,
        DecompressionFailed,
        DimensionsRequired,
        DimensionsTooLarge,
        FilePathTooLong,
        TemporaryFileNotInTempDir,
        TemporaryFileNotNamedCorrectly,
        UnsupportedFormat,
        UnsupportedMedium,
        UnsupportedDepth,
    };

    pub const Data = union(enum) {
        /// Owned, decoded image bytes. The empty default is not allocated.
        complete: []const u8,

        /// Expected decoded byte length for a payload that has not arrived.
        pending: usize,

        /// Bytes reserved against the storage limit.
        pub fn len(self: Data) usize {
            return switch (self) {
                .complete => |data| data.len,
                .pending => |expected_len| expected_len,
            };
        }

        /// Returns decoded bytes when the payload is complete.
        pub fn bytes(self: Data) ?[]const u8 {
            return switch (self) {
                .complete => |data| data,
                .pending => null,
            };
        }

        pub fn isPending(self: Data) bool {
            return self == .pending;
        }

        pub fn deinit(self: *Data, alloc: Allocator) void {
            switch (self.*) {
                .complete => |data| if (data.len > 0) alloc.free(data),
                .pending => {},
            }
        }
    };

    pub fn deinit(self: *Image, alloc: Allocator) void {
        self.data.deinit(alloc);
    }

    /// Mostly for logging
    pub fn withoutData(self: *const Image) Image {
        var copy = self.*;
        if (copy.data == .complete) copy.data = .{ .complete = "" };
        return copy;
    }
};

/// The rect taken up by some image placement, in grid cells. This will
/// be rounded up to the nearest grid cell since we can't place images
/// in partial grid cells.
pub const Rect = struct {
    top_left: PageList.Pin,
    bottom_right: PageList.Pin,

    /// Returns true if the grid cell is inside this rectangle. Pin.isBetween
    /// compares page order, so its interior rows intentionally do not constrain
    /// x. Check the column independently and use isBetween only for the row.
    pub fn contains(self: Rect, cell: PageList.Pin) bool {
        if (cell.x < self.top_left.x or cell.x > self.bottom_right.x) return false;

        var row = cell;
        row.x = self.top_left.x;
        return row.isBetween(self.top_left, self.bottom_right);
    }
};

/// Returns true if `path` is `dir` or is contained within it, requiring a
/// path-separator boundary so similarly prefixed directories do not match.
fn isPathInDir(dir: []const u8, path: []const u8) bool {
    if (dir.len == 0 or !std.mem.startsWith(u8, path, dir)) return false;
    if (path.len == dir.len or std.fs.path.isSep(dir[dir.len - 1])) return true;
    return std.fs.path.isSep(path[dir.len]);
}

test "temporary file path must be inside directory" {
    const testing = std.testing;

    try testing.expect(isPathInDir("/tmp", "/tmp/tty-graphics-protocol-image.data"));
    try testing.expect(isPathInDir("/tmp/", "/tmp/tty-graphics-protocol-image.data"));
    try testing.expect(isPathInDir("/tmp", "/tmp"));

    try testing.expect(!isPathInDir("", "/tmp/tty-graphics-protocol-image.data"));
    try testing.expect(!isPathInDir("/tmp", "/tmpX/tty-graphics-protocol-image.data"));
    try testing.expect(!isPathInDir("/dev/shm", "/dev/shm-evil/tty-graphics-protocol-image.data"));
    try testing.expect(!isPathInDir("/custom/tmp", "/custom/tmp-suffix/tty-graphics-protocol-image.data"));
}

test "shared memory range with offset and size" {
    const testing = std.testing;

    const loading: LoadingImage = .{
        .image = .{
            .width = 1,
            .height = 1,
            .format = .rgb,
        },
        .quiet = .no,
        .temporary_directory = null,
    };

    const explicit = try loading.sharedMemoryRange(.{
        .offset = 2,
        .size = 3,
    }, 5);
    try testing.expectEqual(@as(usize, 2), explicit.start);
    try testing.expectEqual(@as(usize, 5), explicit.end);

    const implicit = try loading.sharedMemoryRange(.{
        .offset = 2,
    }, 5);
    try testing.expectEqual(@as(usize, 2), implicit.start);
    try testing.expectEqual(@as(usize, 5), implicit.end);
}

test "shared memory range rejects out of bounds offset" {
    const loading: LoadingImage = .{
        .image = .{
            .width = 1,
            .height = 1,
            .format = .rgb,
        },
        .quiet = .no,
        .temporary_directory = null,
    };

    try std.testing.expectError(
        error.InvalidData,
        loading.sharedMemoryRange(.{ .offset = 4 }, 3),
    );
}

test "shared memory range validates dimensions before multiplication" {
    const loading: LoadingImage = .{
        .image = .{
            .width = std.math.maxInt(u32),
            .height = std.math.maxInt(u32),
            .format = .rgba,
        },
        .quiet = .no,
        .temporary_directory = null,
    };

    try std.testing.expectError(
        error.DimensionsTooLarge,
        loading.sharedMemoryRange(.{}, 1),
    );
}

// This specifically tests we ALLOW invalid RGB data because Kitty
// documents that this should work.
test "image load with invalid RGB data" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    // <ESC>_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA<ESC>\
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .width = 1,
            .height = 1,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, "AAAA"),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);
}

test "image load with image too wide" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .width = max_dimension + 1,
            .height = 1,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, "AAAA"),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);
    try testing.expectError(error.DimensionsTooLarge, loading.complete(alloc));
}

test "image load with image too tall" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .height = max_dimension + 1,
            .width = 1,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, "AAAA"),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);
    try testing.expectError(error.DimensionsTooLarge, loading.complete(alloc));
}

test "image load: rgb, zlib compressed, direct" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .direct,
            .compression = .zlib_deflate,
            .height = 96,
            .width = 128,
            .image_id = 31,
        } },
        .data = try alloc.dupe(
            u8,
            @embedFile("testdata/image-rgb-zlib_deflate-128x96-2147483647-raw.data"),
        ),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);

    // should be decompressed
    try testing.expect(img.compression == .none);
}

test "image load: rgb, not compressed, direct" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .direct,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(
            u8,
            @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data"),
        ),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);

    // should be decompressed
    try testing.expect(img.compression == .none);
}

test "image load: rgb, zlib compressed, direct, chunked" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const data = @embedFile("testdata/image-rgb-zlib_deflate-128x96-2147483647-raw.data");

    // Setup our initial chunk
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .direct,
            .compression = .zlib_deflate,
            .height = 96,
            .width = 128,
            .image_id = 31,
            .more_chunks = true,
        } },
        .data = try alloc.dupe(u8, data[0..1024]),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);

    // Read our remaining chunks
    var fbs: std.Io.Reader = .fixed(data[1024..]);
    var buf: [1024]u8 = undefined;
    while (fbs.readSliceShort(&buf)) |size| {
        try loading.addData(alloc, buf[0..size]);
        if (size < buf.len) break;
    } else |err| return err;

    // Complete
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
}

test "image load: rgb, zlib compressed, direct, chunked with zero initial chunk" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const data = @embedFile("testdata/image-rgb-zlib_deflate-128x96-2147483647-raw.data");

    // Setup our initial chunk
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .direct,
            .compression = .zlib_deflate,
            .height = 96,
            .width = 128,
            .image_id = 31,
            .more_chunks = true,
        } },
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);

    // Read our remaining chunks
    var fbs: std.Io.Reader = .fixed(data);
    var buf: [1024]u8 = undefined;
    while (fbs.readSliceShort(&buf)) |size| {
        try loading.addData(alloc, buf[0..size]);
        if (size < buf.len) break;
    } else |err| return err;

    // Complete
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
}

test "image load: temporary file without correct path" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "image.data",
        .data = data,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp_dir.dir.realPathFile(testing.io, "image.data", &buf)];

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .temporary_file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectError(error.TemporaryFileNotNamedCorrectly, LoadingImage.init(
        io,
        alloc,
        &cmd,
        .allWithTempDir(dir_path_buf[0..try tmp_dir.dir.realPath(testing.io, &dir_path_buf)]),
    ));

    // Temporary file should still be there
    try tmp_dir.dir.access(testing.io, path, .{});
}

test "image load: temporary file outside directory prefix is rejected" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDir(io, "temp", .default_dir);
    try tmp_dir.dir.createDir(io, "temp-suffix", .default_dir);

    var trusted_dir = try tmp_dir.dir.openDir(io, "temp", .{});
    defer trusted_dir.close(io);
    var outside_dir = try tmp_dir.dir.openDir(io, "temp-suffix", .{});
    defer outside_dir.close(io);

    const filename = "tty-graphics-protocol-image.data";
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try outside_dir.writeFile(io, .{
        .sub_path = filename,
        .data = data,
    });

    var trusted_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const trusted_path = trusted_path_buf[0..try trusted_dir.realPath(io, &trusted_path_buf)];
    var outside_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const outside_path = outside_path_buf[0..try outside_dir.realPathFile(io, filename, &outside_path_buf)];

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .temporary_file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, outside_path),
    };
    defer cmd.deinit(alloc);
    try testing.expectError(
        error.TemporaryFileNotInTempDir,
        LoadingImage.init(io, alloc, &cmd, .allWithTempDir(trusted_path)),
    );

    // Rejection must happen before temporary-file cleanup is armed.
    try outside_dir.access(io, filename, .{});
}

test "image load: rgb, not compressed, temporary file" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "tty-graphics-protocol-image.data",
        .data = data,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp_dir.dir.realPathFile(testing.io, "tty-graphics-protocol-image.data", &buf)];

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .temporary_file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var loading = try LoadingImage.init(
        io,
        alloc,
        &cmd,
        .allWithTempDir(dir_path_buf[0..try tmp_dir.dir.realPath(testing.io, &dir_path_buf)]),
    );
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);

    // Temporary file should be gone
    try testing.expectError(error.FileNotFound, tmp_dir.dir.access(testing.io, path, .{}));
}

test "image load: rgb, not compressed, regular file" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "image.data",
        .data = data,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp_dir.dir.realPathFile(testing.io, "image.data", &buf)];

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var loading = try LoadingImage.init(
        io,
        alloc,
        &cmd,
        .allWithTempDir(dir_path_buf[0..try tmp_dir.dir.realPath(testing.io, &dir_path_buf)]),
    );
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
    try tmp_dir.dir.access(testing.io, path, .{});
}

test "image load: rgb, not compressed, relative regular file" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "image.data",
        .data = data,
    });

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try std.fmt.allocPrint(
            alloc,
            ".zig-cache/tmp/{s}/image.data",
            .{tmp_dir.sub_path},
        ),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(io, alloc, &cmd, .{
        .file = true,
        .temporary_file = .disabled,
        .shared_memory = false,
    });
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
}

test "image load: blocklist applies to opened file after symlink swap" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(io, .{
        .sub_path = "safe.data",
        .data = "safe",
    });
    try tmp_dir.dir.symLink(io, "/dev/null", "image.data", .{});

    // Pin the blocked file, then simulate the cooperating process replacing
    // the path with a safe target before validation.
    const blocked_file = try tmp_dir.dir.openFile(io, "image.data", .{});
    defer blocked_file.close(io);
    try tmp_dir.dir.symLinkAtomic(io, "safe.data", "image.data", .{});

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectError(
        error.InvalidData,
        LoadingImage.validatedFilePath(io, blocked_file, &path_buf),
    );

    // The pathname now resolves to the safe replacement, demonstrating that
    // the rejection above came from the already-open file handle.
    const safe_file = try tmp_dir.dir.openFile(io, "image.data", .{});
    defer safe_file.close(io);
    _ = try LoadingImage.validatedFilePath(io, safe_file, &path_buf);
}

test "image load: png, not compressed, regular file" {
    if (sys.decode_png == null) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-png-none-50x76-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "tty-graphics-protocol-image.data",
        .data = data,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp_dir.dir.realPathFile(testing.io, "tty-graphics-protocol-image.data", &buf)];

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .png,
            .medium = .file,
            .compression = .none,
            .width = 0,
            .height = 0,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var loading = try LoadingImage.init(
        io,
        alloc,
        &cmd,
        .allWithTempDir(dir_path_buf[0..try tmp_dir.dir.realPath(testing.io, &dir_path_buf)]),
    );
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
    try testing.expect(img.format == .rgba);
    try tmp_dir.dir.access(testing.io, path, .{});
}

test "image load: png rejects oversized decoder allocation" {
    const testing = std.testing;

    const oversized_decoder = struct {
        fn decode(
            alloc: Allocator,
            _: []const u8,
        ) sys.DecodeError!sys.Image {
            const data = try alloc.alloc(u8, max_size + 1);
            return .{
                .width = 1,
                .height = 1,
                .data = data,
            };
        }
    }.decode;

    const original_decode_png = sys.decode_png;
    defer sys.decode_png = original_decode_png;
    sys.decode_png = &oversized_decoder;

    // Fail any allocation which reaches the underlying allocator. The size
    // limiter should reject the decoder's request before it gets that far.
    var failing = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });
    const alloc = failing.allocator();

    var loading: LoadingImage = .{
        .image = .{ .format = .png },
        .quiet = .no,
        .temporary_directory = null,
    };
    defer loading.deinit(alloc);

    try testing.expectError(error.InvalidData, loading.complete(alloc));
    try testing.expect(!failing.has_induced_failure);
}

test "image load: png rejects oversized Wuffs image before allocation" {
    if (sys.decode_png == null) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    // Turn the small test PNG into a 32768x32767 image. Its decoded RGBA
    // size is just under Wuffs' 4 GiB package limit but over Kitty's 400 MiB
    // limit, which previously allowed the large allocation to happen first.
    var data = @embedFile("testdata/image-png-none-50x76-2147483647-raw.data").*;
    std.mem.writeInt(u32, data[16..20], 32768, .big);
    std.mem.writeInt(u32, data[20..24], 32767, .big);
    std.mem.writeInt(u32, data[29..33], std.hash.Crc32.hash(data[12..29]), .big);

    const cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .png,
            .medium = .direct,
        } },
        .data = &data,
    };
    var loading = try LoadingImage.init(testing.io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);

    try testing.expectError(error.InvalidData, loading.complete(alloc));
}

test "limits: direct medium always allowed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .direct,
            .width = 1,
            .height = 1,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, "AAAA"),
    };
    defer cmd.deinit(alloc);

    // Direct medium should work even with the most restrictive limits
    var loading = try LoadingImage.init(io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);
}

test "limits: file medium blocked by limits" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "image.data",
        .data = data,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp_dir.dir.realPathFile(testing.io, "image.data", &buf)];

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    try testing.expectError(error.UnsupportedMedium, LoadingImage.init(io, alloc, &cmd, .direct));
}

test "limits: file medium allowed by limits" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "image.data",
        .data = data,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp_dir.dir.realPathFile(testing.io, "image.data", &buf)];

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(io, alloc, &cmd, .{
        .file = true,
        .temporary_file = .disabled,
        .shared_memory = false,
    });
    defer loading.deinit(alloc);
}

test "limits: temporary file medium blocked by limits" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "tty-graphics-protocol-image.data",
        .data = data,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp_dir.dir.realPathFile(testing.io, "tty-graphics-protocol-image.data", &buf)];

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .temporary_file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    try testing.expectError(error.UnsupportedMedium, LoadingImage.init(io, alloc, &cmd, .{
        .file = true,
        .temporary_file = .disabled,
        .shared_memory = true,
    }));

    // File should still exist since we blocked before reading
    try tmp_dir.dir.access(testing.io, "tty-graphics-protocol-image.data", .{});
}

test "limits: temporary file medium allowed by limits" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "tty-graphics-protocol-image.data",
        .data = data,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp_dir.dir.realPathFile(testing.io, "tty-graphics-protocol-image.data", &buf)];

    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .temporary_file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var loading = try LoadingImage.init(
        io,
        alloc,
        &cmd,

        .{
            .file = false,
            .temporary_file = .{
                .enabled = .{ .directory = dir_path_buf[0..try tmp_dir.dir.realPath(testing.io, &dir_path_buf)] },
            },
            .shared_memory = false,
        },
    );
    defer loading.deinit(alloc);
}
