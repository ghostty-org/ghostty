const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const posix = std.posix;

const fastmem = @import("../../fastmem.zig");
const command = @import("graphics_command.zig");
const point = @import("../point.zig");
const PageList = @import("../PageList.zig");
const internal_os = @import("../../os/main.zig");
const wuffs = @import("wuffs");

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
    data: std.ArrayListUnmanaged(u8) = .{},

    /// This is non-null when a transmit and display command is given
    /// so that we display the image after it is fully loaded.
    display: ?command.Display = null,

    /// Quiet is the quiet settings for the initial load command. This is
    /// used if q isn't set on subsequent chunks.
    quiet: command.Command.Quiet,

    /// Initialize a chunked immage from the first image transmission.
    /// If this is a multi-chunk image, this should only be the FIRST
    /// chunk.
    pub fn init(alloc: Allocator, cmd: *const command.Command) !LoadingImage {
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
            },

            .display = cmd.display(),
            .quiet = cmd.quiet,
        };

        // Special case for the direct medium, we just add the chunk directly.
        if (t.medium == .direct) {
            try result.addData(alloc, cmd.data);
            return result;
        }

        // Otherwise, the payload data is guaranteed to be a path.

        if (comptime builtin.os.tag != .windows) {
            if (std.mem.indexOfScalar(u8, cmd.data, 0) != null) {
                // posix.realpath *asserts* that the path does not have
                // internal nulls instead of erroring.
                log.warn("failed to get absolute path: BadPathName", .{});
                return error.InvalidData;
            }
        }

        var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = switch (t.medium) {
            .direct => unreachable, // handled above
            .file, .temporary_file => posix.realpath(cmd.data, &abs_buf) catch |err| {
                log.warn("failed to get absolute path: {}", .{err});
                return error.InvalidData;
            },
            .shared_memory => cmd.data,
        };

        // Depending on the medium, load the data from the path.
        switch (t.medium) {
            .direct => unreachable, // handled above
            .file => try result.readFile(.file, alloc, t, path),
            .temporary_file => try result.readFile(.temporary_file, alloc, t, path),
            .shared_memory => try result.readSharedMemory(alloc, t, path),
        }

        return result;
    }

    /// Reads the data from a shared memory segment.
    fn readSharedMemory(
        self: *LoadingImage,
        alloc: Allocator,
        t: command.Transmission,
        path: []const u8,
    ) !void {
        // windows is currently unsupported, does it support shm?
        if (comptime builtin.target.os.tag == .windows) {
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

        const fd = std.c.shm_open(pathz, @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })), 0);
        switch (std.posix.errno(fd)) {
            .SUCCESS => {},
            else => |err| {
                log.warn("unable to open shared memory {s}: {}", .{ path, err });
                return error.InvalidData;
            },
        }
        defer _ = std.c.close(fd);
        defer _ = std.c.shm_unlink(pathz);

        // The size from stat on may be larger than our expected size because
        // shared memory has to be a multiple of the page size.
        const stat_size: usize = stat: {
            const stat = std.posix.fstat(fd) catch |err| {
                log.warn("unable to fstat shared memory {s}: {}", .{ path, err });
                return error.InvalidData;
            };
            if (stat.size <= 0) return error.InvalidData;
            break :stat @intCast(stat.size);
        };

        const expected_size: usize = switch (self.image.format) {
            // Png we decode the full data size because later decoding will
            // get the proper dimensions and assert validity.
            .png => stat_size,

            // For these formats we have a size we must have.
            .gray, .gray_alpha, .rgb, .rgba => |f| size: {
                const bpp = f.bpp();
                break :size self.image.width * self.image.height * bpp;
            },
        };

        // Our stat size must be at least the expected size otherwise
        // the shared memory data is invalid.
        if (stat_size < expected_size) {
            log.warn(
                "shared memory size too small expected={} actual={}",
                .{ expected_size, stat_size },
            );
            return error.InvalidData;
        }

        const map = std.posix.mmap(
            null,
            stat_size, // mmap always uses the stat size
            std.c.PROT.READ,
            std.c.MAP{ .TYPE = .SHARED },
            fd,
            0,
        ) catch |err| {
            log.warn("unable to mmap shared memory {s}: {}", .{ path, err });
            return error.InvalidData;
        };
        defer std.posix.munmap(map);

        // Our end size always uses the expected size so we cut off the
        // padding for mmap alignment.
        const start: usize = @intCast(t.offset);
        const end: usize = if (t.size > 0) @min(
            @as(usize, @intCast(t.offset)) + @as(usize, @intCast(t.size)),
            expected_size,
        ) else expected_size;

        assert(self.data.items.len == 0);
        try self.data.appendSlice(alloc, map[start..end]);
    }

    /// Reads the data from a temporary file and returns it. This allocates
    /// and does not free any of the data, so the caller must free it.
    ///
    /// This will also delete the temporary file if it is in a safe location.
    fn readFile(
        self: *LoadingImage,
        comptime medium: command.Transmission.Medium,
        alloc: Allocator,
        t: command.Transmission,
        path: []const u8,
    ) !void {
        switch (medium) {
            .file, .temporary_file => {},
            else => @compileError("readFile only supports file and temporary_file"),
        }

        // Verify file seems "safe". This is logic copied directly from Kitty,
        // mostly. This is really rough but it will catch obvious bad actors.
        if (std.mem.startsWith(u8, path, "/proc/") or
            std.mem.startsWith(u8, path, "/sys/") or
            (std.mem.startsWith(u8, path, "/dev/") and
                !std.mem.startsWith(u8, path, "/dev/shm/")))
        {
            return error.InvalidData;
        }

        // Temporary file logic
        if (medium == .temporary_file) {
            if (!isPathInTempDir(path)) return error.TemporaryFileNotInTempDir;
            if (std.mem.indexOf(u8, path, "tty-graphics-protocol") == null) {
                return error.TemporaryFileNotNamedCorrectly;
            }
        }
        defer if (medium == .temporary_file) {
            posix.unlink(path) catch |err| {
                log.warn("failed to delete temporary file: {}", .{err});
            };
        };

        var file = std.fs.cwd().openFile(path, .{}) catch |err| {
            log.warn("failed to open temporary file: {}", .{err});
            return error.InvalidData;
        };
        defer file.close();

        // File must be a regular file
        if (file.stat()) |stat| {
            if (stat.kind != .file) {
                log.warn("file is not a regular file kind={}", .{stat.kind});
                return error.InvalidData;
            }
        } else |err| {
            log.warn("failed to stat file: {}", .{err});
            return error.InvalidData;
        }

        if (t.offset > 0) {
            file.seekTo(@intCast(t.offset)) catch |err| {
                log.warn("failed to seek to offset {}: {}", .{ t.offset, err });
                return error.InvalidData;
            };
        }

        var buf_reader = std.io.bufferedReader(file.reader());
        const reader = buf_reader.reader();

        // Read the file
        var managed = std.ArrayList(u8).init(alloc);
        errdefer managed.deinit();
        const size: usize = if (t.size > 0) @min(t.size, max_size) else max_size;
        reader.readAllArrayList(&managed, size) catch |err| {
            log.warn("failed to read temporary file: {}", .{err});
            return error.InvalidData;
        };

        // Set our data
        assert(self.data.items.len == 0);
        self.data = .{ .items = managed.items, .capacity = managed.capacity };
    }

    /// Returns true if path appears to be in a temporary directory.
    /// Copies logic from Kitty.
    fn isPathInTempDir(path: []const u8) bool {
        if (std.mem.startsWith(u8, path, "/tmp")) return true;
        if (std.mem.startsWith(u8, path, "/dev/shm")) return true;
        if (internal_os.allocTmpDir(std.heap.page_allocator)) |dir| {
            defer internal_os.freeTmpDir(std.heap.page_allocator, dir);
            if (std.mem.startsWith(u8, path, dir)) return true;

            // The temporary dir is sometimes a symlink. On macOS for
            // example /tmp is /private/var/...
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            if (posix.realpath(dir, &buf)) |real_dir| {
                if (std.mem.startsWith(u8, path, real_dir)) return true;
            } else |_| {}
        }

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
        const bpp = img.format.bpp();
        const expected_len = img.width * img.height * bpp;
        const actual_len = self.data.items.len;
        if (actual_len != expected_len) {
            std.log.warn(
                "unexpected length image id={} width={} height={} bpp={} expected_len={} actual_len={}",
                .{ img.id, img.width, img.height, bpp, expected_len, actual_len },
            );
            return error.InvalidData;
        }

        // Set our time
        self.image.transmit_time = std.time.Instant.now() catch |err| {
            log.warn("failed to get time: {}", .{err});
            return error.InternalError;
        };

        // Everything looks good, copy the image data over.
        var result = self.image;
        result.data = try self.data.toOwnedSlice(alloc);
        errdefer result.deinit(alloc);
        self.image = .{};
        return result;
    }

    /// Debug function to write the data to a file. This is useful for
    /// capturing some test data for unit tests.
    pub fn debugDump(self: LoadingImage) !void {
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
        const cwd = std.fs.cwd();
        const f = try cwd.createFile(filename, .{});
        defer f.close();

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
        var fbs = std.io.fixedBufferStream(self.data.items);
        var stream = std.compress.zlib.decompressor(fbs.reader());

        // Write it to an array list
        var list = std.ArrayList(u8).init(alloc);
        errdefer list.deinit();
        stream.reader().readAllArrayList(&list, max_size) catch |err| {
            log.warn("failed to read decompressed data: {}", .{err});
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

        const result = wuffs.png.decode(
            alloc,
            self.data.items,
        ) catch |err| switch (err) {
            error.WuffsError => return error.InvalidData,
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer alloc.free(result.data);

        if (result.data.len > max_size) {
            log.warn("png image too large size={} max_size={}", .{ result.data.len, max_size });
            return error.InvalidData;
        }

        // Replace our data
        self.data.deinit(alloc);
        self.data = .{};
        try self.data.ensureUnusedCapacity(alloc, result.data.len);
        try self.data.appendSlice(alloc, result.data[0..result.data.len]);

        // Store updated image dimensions
        self.image.width = result.width;
        self.image.height = result.height;
        self.image.format = .rgba;
    }
};

/// Image represents a single fully loaded image.
pub const Image = struct {
    id: u32 = 0,
    number: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    format: command.Transmission.Format = .rgb,
    compression: command.Transmission.Compression = .none,
    data: []const u8 = "",
    transmit_time: std.time.Instant = undefined,

    /// Set this to true if this image was loaded by a command that
    /// doesn't specify an ID or number, since such commands should
    /// not be responded to, even though we do currently give them
    /// IDs in the public range (which is bad!).
    implicit_id: bool = false,

    pub const Error = error{
        InternalError,
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

    pub fn deinit(self: *Image, alloc: Allocator) void {
        if (self.data.len > 0) alloc.free(self.data);
    }

    /// Mostly for logging
    pub fn withoutData(self: *const Image) Image {
        var copy = self.*;
        copy.data = "";
        return copy;
    }
};

/// The rect taken up by some image placement, in grid cells. This will
/// be rounded up to the nearest grid cell since we can't place images
/// in partial grid cells.
pub const Rect = struct {
    top_left: PageList.Pin,
    bottom_right: PageList.Pin,
};

// This specifically tests we ALLOW invalid RGB data because Kitty
// documents that this should work.
test "image load with invalid RGB data" {
    const testing = std.testing;
    const alloc = testing.allocator;

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
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);
}

test "image load with image too wide" {
    const testing = std.testing;
    const alloc = testing.allocator;

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
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);
    try testing.expectError(error.DimensionsTooLarge, loading.complete(alloc));
}

test "image load with image too tall" {
    const testing = std.testing;
    const alloc = testing.allocator;

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
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);
    try testing.expectError(error.DimensionsTooLarge, loading.complete(alloc));
}

test "image load: rgb, zlib compressed, direct" {
    const testing = std.testing;
    const alloc = testing.allocator;

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
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);

    // should be decompressed
    try testing.expect(img.compression == .none);
}

test "image load: rgb, not compressed, direct" {
    const testing = std.testing;
    const alloc = testing.allocator;

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
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);

    // should be decompressed
    try testing.expect(img.compression == .none);
}

test "image load: rgb, zlib compressed, direct, chunked" {
    const testing = std.testing;
    const alloc = testing.allocator;

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
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);

    // Read our remaining chunks
    var fbs = std.io.fixedBufferStream(data[1024..]);
    var buf: [1024]u8 = undefined;
    while (fbs.reader().readAll(&buf)) |size| {
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
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);

    // Read our remaining chunks
    var fbs = std.io.fixedBufferStream(data);
    var buf: [1024]u8 = undefined;
    while (fbs.reader().readAll(&buf)) |size| {
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

    var tmp_dir = try internal_os.TempDir.init();
    defer tmp_dir.deinit();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "image.data",
        .data = data,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("image.data", &buf);

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
    try testing.expectError(error.TemporaryFileNotNamedCorrectly, LoadingImage.init(alloc, &cmd));

    // Temporary file should still be there
    try tmp_dir.dir.access(path, .{});
}

test "image load: rgb, not compressed, temporary file" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp_dir = try internal_os.TempDir.init();
    defer tmp_dir.deinit();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "tty-graphics-protocol-image.data",
        .data = data,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("tty-graphics-protocol-image.data", &buf);

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
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);

    // Temporary file should be gone
    try testing.expectError(error.FileNotFound, tmp_dir.dir.access(path, .{}));
}

test "image load: rgb, not compressed, regular file" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp_dir = try internal_os.TempDir.init();
    defer tmp_dir.deinit();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "image.data",
        .data = data,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("image.data", &buf);

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
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
    try tmp_dir.dir.access(path, .{});
}

test "image load: png, not compressed, regular file" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp_dir = try internal_os.TempDir.init();
    defer tmp_dir.deinit();
    const data = @embedFile("testdata/image-png-none-50x76-2147483647-raw.data");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "tty-graphics-protocol-image.data",
        .data = data,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("tty-graphics-protocol-image.data", &buf);

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
    var loading = try LoadingImage.init(alloc, &cmd);
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
    try testing.expect(img.format == .rgba);
    try tmp_dir.dir.access(path, .{});
}
