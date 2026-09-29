//! Tests for TinyIo that only touch its public surface, so they run on
//! every supported platform. Platform-specific tests live next to the
//! platform arm they exercise.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const Threaded = std.Io.Threaded;
const TinyIo = @import("../TinyIo.zig");
const supported = TinyIo.supported;

const is_windows = builtin.os.tag == .windows;
const windows = std.os.windows;
const os_windows = @import("../../os/windows.zig");
const ntdll = os_windows.exp.ntdll;
const kernel32 = os_windows.exp.kernel32;
const HANDLE = windows.HANDLE;

/// Reads until every buffer is full or the stream ends. POSIX readv fills
/// all buffers in one call; NT reads one buffer per call.
fn readStreamingAll(file: File, io_: Io, buffers: []const []u8) !usize {
    var remaining: [8][]u8 = undefined;
    std.debug.assert(buffers.len <= remaining.len);
    @memcpy(remaining[0..buffers.len], buffers);
    var list: [][]u8 = remaining[0..buffers.len];

    var total: usize = 0;
    while (list.len > 0) {
        var n = file.readStreaming(io_, list) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        total += n;
        while (list.len > 0 and n >= list[0].len) {
            n -= list[0].len;
            list = list[1..];
        }
        if (list.len > 0) list[0] = list[0][n..];
    }
    return total;
}

test "read a file through File.Reader" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const contents = "hello minimal test_io\n" ** 100;
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "test.txt",
        .data = contents,
    });

    // Open through our Io. The Dir handle is a plain fd, so it is usable
    // across Io implementations.
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    var file = try dir.openFile(test_io, "test.txt", .{});
    defer file.close(test_io);

    // Stat through our Io.
    const stat = try file.stat(test_io);
    try testing.expectEqual(@as(u64, contents.len), stat.size);
    try testing.expectEqual(File.Kind.file, stat.kind);

    // fileLength.
    try testing.expectEqual(@as(u64, contents.len), try file.length(test_io));

    // Read it all back through File.Reader (exercises positional reads
    // and streaming fallbacks).
    var buf: [64]u8 = undefined;
    var reader = file.reader(test_io, &buf);
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try reader.interface.appendRemaining(testing.allocator, &list, .unlimited);
    try testing.expectEqualStrings(contents, list.items);
}

test "seek" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "seek.txt",
        .data = "0123456789",
    });

    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    var file = try dir.openFile(test_io, "seek.txt", .{});
    defer file.close(test_io);

    // Exercise our seek and streaming read implementations directly at
    // the vtable level; the higher-level File.Reader seek plumbing has
    // its own buffering behaviors that are independent of the Io
    // implementation.
    var out: [4]u8 = undefined;
    var slices = [_][]u8{&out};

    try test_io.vtable.fileSeekTo(test_io.userdata, file, 6);
    var n = try file.readStreaming(test_io, &slices);
    try testing.expectEqualStrings("6789", out[0..n]);

    // Seek back relative and re-read.
    try test_io.vtable.fileSeekBy(test_io.userdata, file, -8);
    n = try file.readStreaming(test_io, &slices);
    try testing.expectEqualStrings("2345", out[0..n]);

    // Positional reads are independent of the seek position.
    var pslices = [_][]u8{&out};
    n = try test_io.vtable.fileReadPositional(test_io.userdata, file, &pslices, 1);
    try testing.expectEqualStrings("1234", out[0..n]);
}

test "realPath and deleteFile" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    // Only platforms with a real implementation.
    switch (builtin.os.tag) {
        .macos, .ios, .linux, .freebsd, .windows => {},
        else => return error.SkipZigTest,
    }

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "real.txt",
        .data = "x",
    });

    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    var file = try dir.openFile(test_io, "real.txt", .{});
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try file.realPath(test_io, &path_buf)];
    try testing.expect(std.mem.endsWith(u8, path, "real.txt"));
    file.close(test_io);

    // dirRealPathFile via absolute path from cwd.
    var path_buf2: [std.fs.max_path_bytes]u8 = undefined;
    const path2 = path_buf2[0..try Dir.cwd().realPathFile(test_io, path, &path_buf2)];
    try testing.expectEqualStrings(path, path2);

    // Delete it through our Io, verify it is gone.
    try dir.deleteFile(test_io, "real.txt");
    try testing.expectError(error.FileNotFound, dir.openFile(test_io, "real.txt", .{}));
}

test "openFile of a directory returns IsDir" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDir(testing.io, "sub", .default_dir);
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    try testing.expectError(error.IsDir, dir.openFile(test_io, "sub", .{
        .allow_directory = false,
    }));
}

test "Io.Mutex through TinyIo" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    // Contended and uncontended lock/unlock; exercises the futex ops.
    var mutex: Io.Mutex = .init;
    mutex.lockUncancelable(test_io);
    mutex.unlock(test_io);

    // Wake with no waiters must be a no-op.
    var word: u32 = 0;
    test_io.vtable.futexWake(test_io.userdata, &word, 1);

    // Wait with a non-matching expected value must return immediately.
    test_io.vtable.futexWaitUncancelable(test_io.userdata, &word, 1);
}

test "randomSecure fills with fresh entropy" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    var a: [32]u8 = @splat(0);
    var b: [32]u8 = @splat(0);
    try test_io.randomSecure(&a);
    try test_io.randomSecure(&b);

    // Non-zero and non-repeating. A zero fill is what `random` does
    // without a source, which would make every one-time password the
    // same; identical draws would mean the same thing.
    try testing.expect(!std.mem.allEqual(u8, &a, 0));
    try testing.expect(!std.mem.allEqual(u8, &b, 0));
    try testing.expect(!std.mem.eql(u8, &a, &b));

    // Zero-length is a no-op.
    try test_io.randomSecure(a[0..0]);
}

test "unused operations fail gracefully" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    try testing.expectError(
        error.NoSpaceLeft,
        dir.createFile(test_io, "nope.txt", .{}),
    );
}

test "openFile edge cases" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "edge.txt",
        .data = "edge",
    });
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };

    // File locking is unimplemented and must be reported, not ignored.
    try testing.expectError(error.FileLocksUnsupported, dir.openFile(
        test_io,
        "edge.txt",
        .{ .lock = .shared },
    ));

    // NUL bytes never form a valid path.
    try testing.expectError(error.BadPathName, dir.openFile(
        test_io,
        "bad\x00path",
        .{},
    ));

    // Paths that can't fit in PATH_MAX must not be silently truncated.
    const long_name = "a" ** (std.fs.max_path_bytes + 1);
    try testing.expectError(error.NameTooLong, dir.openFile(
        test_io,
        long_name,
        .{},
    ));

    // A path component that is a file, not a directory. NT reports this
    // as the path not existing (Threaded does too) rather than ENOTDIR.
    try testing.expectError(
        if (comptime is_windows) error.FileNotFound else error.NotDir,
        dir.openFile(test_io, "edge.txt/child", .{}),
    );

    // Directories may be opened when allowed (the default) and stat
    // reports their kind.
    try tmp_dir.dir.createDir(testing.io, "subdir", .default_dir);
    var dir_file = try dir.openFile(test_io, "subdir", .{});
    const dir_stat = try dir_file.stat(test_io);
    try testing.expectEqual(File.Kind.directory, dir_stat.kind);
    dir_file.close(test_io);

    // Write modes translate to the right ACCMODE flags; TinyIo can't
    // write but opening for write must succeed.
    var wfile = try dir.openFile(test_io, "edge.txt", .{ .mode = .write_only });
    wfile.close(test_io);
    var rwfile = try dir.openFile(test_io, "edge.txt", .{ .mode = .read_write });
    rwfile.close(test_io);
}

test "openFile symlink handling" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    // Platforms where we know both symlink creation (via the testing Io)
    // and O_NOFOLLOW behave as expected.
    switch (builtin.os.tag) {
        .macos, .ios, .linux, .freebsd => {},
        else => return error.SkipZigTest,
    }

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "target.txt",
        .data = "target",
    });
    try tmp_dir.dir.symLink(testing.io, "target.txt", "link.txt", .{});
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };

    // Following symlinks (the default) opens the target...
    var file = try dir.openFile(test_io, "link.txt", .{});
    try testing.expectEqual(@as(u64, "target".len), try file.length(test_io));

    // ...and realPath resolves through the link to the target. This is
    // the property the Kitty graphics path validation relies on.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try file.realPath(test_io, &path_buf)];
    try testing.expect(std.mem.endsWith(u8, path, "target.txt"));
    file.close(test_io);

    // Refusing to follow symlinks fails with SymLinkLoop.
    try testing.expectError(error.SymLinkLoop, dir.openFile(
        test_io,
        "link.txt",
        .{ .follow_symlinks = false },
    ));
}

test "positional reads at and beyond EOF return zero" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "eof.txt",
        .data = "0123456789",
    });
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    var file = try dir.openFile(test_io, "eof.txt", .{});
    defer file.close(test_io);

    var out: [4]u8 = undefined;
    var slices = [_][]u8{&out};

    // At EOF and past EOF: the vtable contract is "returns 0 if reading
    // at or past the end".
    try testing.expectEqual(@as(usize, 0), try test_io.vtable.fileReadPositional(
        test_io.userdata,
        file,
        &slices,
        10,
    ));
    try testing.expectEqual(@as(usize, 0), try test_io.vtable.fileReadPositional(
        test_io.userdata,
        file,
        &slices,
        9999,
    ));

    // No buffers and only-empty buffers read nothing without a syscall.
    try testing.expectEqual(@as(usize, 0), try test_io.vtable.fileReadPositional(
        test_io.userdata,
        file,
        &.{},
        0,
    ));
    var empty = [_][]u8{ &.{}, &.{} };
    try testing.expectEqual(@as(usize, 0), try test_io.vtable.fileReadPositional(
        test_io.userdata,
        file,
        &empty,
        0,
    ));
}

test "vectored reads scatter across buffers" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "vec.txt",
        .data = "0123456789abcdef",
    });
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    var file = try dir.openFile(test_io, "vec.txt", .{});
    defer file.close(test_io);

    // Scatter a positional read across multiple buffers, with empty
    // buffers interleaved (they must be skipped).
    var a: [4]u8 = undefined;
    var b: [2]u8 = undefined;
    var c: [6]u8 = undefined;
    var slices = [_][]u8{ &a, &.{}, &b, &c };
    const n = try test_io.vtable.fileReadPositional(
        test_io.userdata,
        file,
        &slices,
        0,
    );
    try testing.expectEqual(@as(usize, 12), n);
    try testing.expectEqualStrings("0123", &a);
    try testing.expectEqualStrings("45", &b);
    try testing.expectEqualStrings("6789ab", &c);

    // More buffers than max_iovecs_len: reads are truncated to the
    // first max_iovecs_len non-empty buffers (partial reads are allowed
    // by the vtable contract; callers retry).
    comptime std.debug.assert(Threaded.max_iovecs_len < 16);
    var bytes: [16][1]u8 = undefined;
    var many: [16][]u8 = undefined;
    for (&many, &bytes) |*s, *byte| s.* = byte;
    const n2 = try test_io.vtable.fileReadPositional(
        test_io.userdata,
        file,
        &many,
        0,
    );
    try testing.expectEqual(@as(usize, Threaded.max_iovecs_len), n2);
    for (bytes[0..n2], "0123456789abcdef"[0..n2]) |got, want| {
        try testing.expectEqual(want, got[0]);
    }
}

test "streaming reads: EndOfStream and scatter" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "stream.txt",
        .data = "streaming!",
    });
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    var file = try dir.openFile(test_io, "stream.txt", .{});
    defer file.close(test_io);

    // Scatter a streaming read (one readv on POSIX, one NtReadFile per
    // buffer on Windows).
    var a: [6]u8 = undefined;
    var b: [4]u8 = undefined;
    var slices = [_][]u8{ &a, &b };
    try testing.expectEqual(@as(usize, 10), try readStreamingAll(file, test_io, &slices));
    try testing.expectEqualStrings("stream", &a);
    try testing.expectEqualStrings("ing!", &b);

    // Reading again at EOF is a stream end, not a zero-length success.
    try testing.expectError(error.EndOfStream, file.readStreaming(test_io, &slices));

    // Empty destinations read nothing.
    try testing.expectEqual(@as(usize, 0), try file.readStreaming(test_io, &.{}));

    // Seeking beyond EOF is legal; the next streaming read hits EOF.
    try test_io.vtable.fileSeekTo(test_io.userdata, file, 9999);
    try testing.expectError(error.EndOfStream, file.readStreaming(test_io, &slices));

    // And seeking back to zero re-reads from the start.
    try test_io.vtable.fileSeekTo(test_io.userdata, file, 0);
    try testing.expectEqual(@as(usize, 10), try readStreamingAll(file, test_io, &slices));
    try testing.expectEqualStrings("stream", &a);
}

test "pipes: streaming works; positional and seek are Unseekable or ignored" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    const msg = "through the pipe";
    const read_end: File = if (comptime is_windows) pipe: {
        var read_h: HANDLE = undefined;
        var write_h: HANDLE = undefined;
        if (!kernel32.CreatePipe(&read_h, &write_h, null, 0).toBool()) {
            return error.SkipZigTest;
        }
        defer _ = ntdll.NtClose(write_h);
        // Twice, so a second read after the streaming one has data.
        for (0..2) |_| {
            var iosb: os_windows.IO_STATUS_BLOCK = undefined;
            try testing.expectEqual(.SUCCESS, windows.ntdll.NtWriteFile(
                write_h,
                null,
                null,
                null,
                &iosb,
                msg.ptr,
                msg.len,
                null,
                null,
            ));
        }
        break :pipe .{ .handle = read_h, .flags = .{ .nonblocking = false } };
    } else pipe: {
        var fds: [2]posix.fd_t = undefined;
        switch (posix.errno(posix.system.pipe(&fds))) {
            .SUCCESS => {},
            else => return error.SkipZigTest,
        }
        defer _ = posix.system.close(fds[1]);
        try testing.expectEqual(
            @as(isize, msg.len),
            @as(isize, @intCast(posix.system.write(fds[1], msg, msg.len))),
        );
        break :pipe .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    };
    defer read_end.close(test_io);

    // Streaming reads work on unseekable files; this is the fallback
    // File.Reader depends on when positional reads report Unseekable.
    var buf: [msg.len]u8 = undefined;
    var slices = [_][]u8{&buf};
    try testing.expectEqual(@as(usize, msg.len), try read_end.readStreaming(test_io, &slices));
    try testing.expectEqualStrings(msg, &buf);

    if (comptime is_windows) {
        // NT pipes accept a byte offset and a file position but ignore
        // both: reads stay sequential and seeks succeed without effect.
        // Threaded behaves the same way, so TinyIo mirrors it rather than
        // spending a syscall per read to detect pipes.
        @memset(&buf, 0);
        try testing.expectEqual(@as(usize, msg.len), try test_io.vtable.fileReadPositional(
            test_io.userdata,
            read_end,
            &slices,
            8,
        ));
        try testing.expectEqualStrings(msg, &buf);
        try test_io.vtable.fileSeekTo(test_io.userdata, read_end, 0);
        try test_io.vtable.fileSeekBy(test_io.userdata, read_end, 1);

        // Drained with the writer closed is the end of the stream.
        try testing.expectError(error.EndOfStream, read_end.readStreaming(test_io, &slices));
        return;
    }

    // Positional reads and seeks must report Unseekable so callers can
    // fall back to streaming.
    try testing.expectError(error.Unseekable, test_io.vtable.fileReadPositional(
        test_io.userdata,
        read_end,
        &slices,
        0,
    ));
    try testing.expectError(error.Unseekable, test_io.vtable.fileSeekTo(
        test_io.userdata,
        read_end,
        0,
    ));
    try testing.expectError(error.Unseekable, test_io.vtable.fileSeekBy(
        test_io.userdata,
        read_end,
        1,
    ));
}

test "operate delegates non-read operations to failing stubs" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "w.txt",
        .data = "x",
    });
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    var file = try dir.openFile(test_io, "w.txt", .{ .mode = .write_only });
    defer file.close(test_io);

    const result = try test_io.vtable.operate(test_io.userdata, .{
        .file_write_streaming = .{
            .file = file,
            .data = &.{"nope"},
        },
    });
    try testing.expectError(error.InputOutput, result.file_write_streaming);
}

test "dirRealPathFile edge cases" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    switch (builtin.os.tag) {
        .macos, .ios, .linux, .freebsd, .windows => {},
        else => return error.SkipZigTest,
    }

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "real.txt",
        .data = "x",
    });
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };

    // Resolve the canonical path through an open file for reference.
    var file = try dir.openFile(test_io, "real.txt", .{});
    var want_buf: [std.fs.max_path_bytes]u8 = undefined;
    const want = want_buf[0..try file.realPath(test_io, &want_buf)];
    file.close(test_io);

    // A non-cwd directory handle exercises the open-then-resolve
    // fallback branch rather than libc realpath.
    var got_buf: [std.fs.max_path_bytes]u8 = undefined;
    const got = got_buf[0..try test_io.vtable.dirRealPathFile(
        test_io.userdata,
        dir,
        "real.txt",
        &got_buf,
    )];
    try testing.expectEqualStrings(want, got);

    // Missing paths report FileNotFound (libc realpath branch, via an
    // absolute path anchored at cwd).
    var missing_buf: [std.fs.max_path_bytes]u8 = undefined;
    const missing = std.fmt.bufPrint(&missing_buf, "{s}.missing", .{want}) catch
        return error.SkipZigTest;
    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectError(error.FileNotFound, Dir.cwd().realPathFile(
        test_io,
        missing,
        &out_buf,
    ));

    // libc realpath requires a PATH_MAX-sized output buffer; smaller
    // buffers must error rather than risk truncation.
    var small_buf: [8]u8 = undefined;
    try testing.expectError(error.NameTooLong, Dir.cwd().realPathFile(
        test_io,
        want,
        &small_buf,
    ));
}

test "deleteFile edge cases" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };

    // Nonexistent files.
    try testing.expectError(error.FileNotFound, dir.deleteFile(test_io, "missing.txt"));

    // NUL bytes never form a valid POSIX path.
    try testing.expectError(error.BadPathName, dir.deleteFile(test_io, "bad\x00path"));

    // Deleting a directory reports IsDir. On BSD-derived systems
    // (including macOS) unlink returns EPERM for directories, which
    // exercises the stat-based disambiguation path.
    try tmp_dir.dir.createDir(testing.io, "subdir", .default_dir);
    try testing.expectError(error.IsDir, dir.deleteFile(test_io, "subdir"));

    // Deleting a symlink removes the link, not its target. Creating one
    // on Windows needs a privilege that plain users and CI lack.
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "target.txt",
        .data = "x",
    });
    tmp_dir.dir.symLink(testing.io, "target.txt", "link.txt", .{}) catch |err| switch (err) {
        error.AccessDenied => if (comptime is_windows) return error.SkipZigTest else return err,
        else => return err,
    };
    try dir.deleteFile(test_io, "link.txt");
    var file = try dir.openFile(test_io, "target.txt", .{});
    file.close(test_io);
    try testing.expectError(error.FileNotFound, dir.openFile(test_io, "link.txt", .{}));
}

test "dirClose closes the descriptor" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDir(testing.io, "subdir", .default_dir);
    const opened = try tmp_dir.dir.openDir(testing.io, "subdir", .{});

    const dir: Dir = .{ .handle = opened.handle };
    test_io.vtable.dirClose(test_io.userdata, &.{dir});

    if (comptime is_windows) {
        // A query on a closed handle fails without raising anything.
        var iosb: os_windows.IO_STATUS_BLOCK = undefined;
        var info: os_windows.FILE_STANDARD_INFORMATION = undefined;
        try testing.expectEqual(.INVALID_HANDLE, ntdll.NtQueryInformationFile(
            dir.handle,
            &iosb,
            &info,
            @sizeOf(os_windows.FILE_STANDARD_INFORMATION),
            .Standard,
        ));
        return;
    }

    // Verify with a raw dup that the fd is gone. We check the errno
    // directly rather than going through our Io so no error path prints
    // "unexpected errno" diagnostics in debug test builds. `dup` rather
    // than `fstat` because glibc has no LFS64 `fstat` symbol, so
    // `fstat_sym` doesn't exist on Linux.
    try testing.expectEqual(posix.E.BADF, posix.errno(posix.system.dup(dir.handle)));
}

test "cancel protection operations are benign" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    // There is no async, so cancelation can never be requested.
    try test_io.vtable.checkCancel(test_io.userdata);

    // Swap and restore roundtrip like generic std code does around
    // uninterruptible sections.
    const prev = test_io.vtable.swapCancelProtection(test_io.userdata, .blocked);
    _ = test_io.vtable.swapCancelProtection(test_io.userdata, prev);
    test_io.vtable.recancel(test_io.userdata);

    _ = testing;
}

test "async runs inline; concurrency is unavailable" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    const S = struct {
        fn work(x: *u32) u32 {
            x.* += 1;
            return x.*;
        }
    };

    // The task must have executed synchronously, before await.
    var state: u32 = 41;
    var future = test_io.async(S.work, .{&state});
    try testing.expectEqual(@as(u32, 42), state);
    try testing.expectEqual(@as(u32, 42), future.await(test_io));

    // Concurrency must be reported as unavailable, not silently run.
    try testing.expectError(
        error.ConcurrencyUnavailable,
        test_io.concurrent(S.work, .{&state}),
    );
    try testing.expectEqual(@as(u32, 42), state);
}

test "futex timed waits return" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();

    // Nobody wakes this futex, so returning at all proves the timeout
    // (or the spurious-wakeup contract) works.
    var word: u32 = 1;
    try test_io.vtable.futexWait(test_io.userdata, &word, 1, .{
        .duration = .{ .raw = .fromNanoseconds(5 * std.time.ns_per_ms), .clock = .awake },
    });

    // Deadlines can't be resolved without a clock; they degrade to a
    // short poll which must also return.
    try test_io.vtable.futexWait(test_io.userdata, &word, 1, .{
        .deadline = .{ .raw = .fromNanoseconds(1), .clock = .awake },
    });

    // A mismatched expected value returns immediately even with no
    // timeout.
    try test_io.vtable.futexWait(test_io.userdata, &word, 2, .none);

    // Waking more than one waiter takes the wake-all path.
    test_io.vtable.futexWake(test_io.userdata, &word, 2);
    test_io.vtable.futexWake(test_io.userdata, &word, std.math.maxInt(u32));
}

test "Io.Mutex under real thread contention" {
    if (comptime !supported) return error.SkipZigTest;
    if (comptime builtin.single_threaded) return error.SkipZigTest;
    const tio: TinyIo = .init;
    const test_io = tio.io();
    const testing = std.testing;

    // Hammer a mutex from several threads so waiters actually park in
    // futexWait and get released by futexWake.
    const S = struct {
        const iterations = 10_000;

        fn worker(m: *Io.Mutex, io_: Io, counter: *u64) void {
            for (0..iterations) |_| {
                m.lockUncancelable(io_);
                defer m.unlock(io_);
                counter.* += 1;
            }
        }
    };

    var mutex: Io.Mutex = .init;
    var counter: u64 = 0;

    const thread_count = 4;
    var threads: [thread_count]std.Thread = undefined;
    var spawned: usize = 0;
    defer for (threads[0..spawned]) |t| t.join();
    for (&threads) |*t| {
        t.* = std.Thread.spawn(.{}, S.worker, .{ &mutex, test_io, &counter }) catch
            break;
        spawned += 1;
    }
    for (threads[0..spawned]) |t| t.join();
    spawned = 0;

    try testing.expectEqual(@as(u64, S.iterations * thread_count), counter);
}
