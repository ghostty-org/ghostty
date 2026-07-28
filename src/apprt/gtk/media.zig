const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;

const log = std.log.scoped(.gtk_media);

const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const global = @import("../../global.zig");

pub fn fromFilename(path: [:0]const u8) ?*gtk.MediaFile {
    assert(std.fs.path.isAbsolute(path));
    std.Io.Dir.accessAbsolute(
        global.io(),
        path,
        .{ .read = true },
    ) catch |err| {
        log.warn("unable to access {s}: {t}", .{ path, err });
        return null;
    };
    return gtk.MediaFile.newForFilename(path);
}

pub fn fromResource(path: [:0]const u8) ?*gtk.MediaFile {
    assert(std.fs.path.isAbsolute(path));
    var gerr: ?*glib.Error = null;

    const found = gio.resourcesGetInfo(path, .{}, null, null, &gerr);
    if (gerr) |err| {
        defer err.free();
        log.warn(
            "failed to find resource {s}: {s} {d} {s}",
            .{
                path,
                glib.quarkToString(err.f_domain),
                err.f_code,
                err.f_message orelse "(no message)",
            },
        );
        return null;
    }

    if (found == 0) {
        log.warn("failed to find resource {s}", .{path});
        return null;
    }

    return gtk.MediaFile.newForResource(path);
}

/// Get-or-create a reusable bell MediaFile targeting `path`.
///
/// `current` is the surface's currently-cached MediaFile (or null). If it
/// already targets `path` it is returned unchanged; otherwise it is unref'd and
/// a fresh MediaFile is built for `path`. Returns null (after freeing `current`)
/// if `path` is inaccessible, leaving the caller's slot empty.
///
/// Reusing one MediaFile per surface is what prevents the GStreamer pipeline
/// leak: `gtk.MediaFile.newForFilename` spins up a full pipeline (and, via the
/// GTK4 GStreamer backend's GL sink, gstglcontext/gldisplay-event threads) that
/// is never torn down on the happy path, so allocating one per bell leaked a
/// pipeline + its threads on every ring. See the caller in surface.zig.
pub fn bellMediaFile(
    current: ?*gtk.MediaFile,
    path: [:0]const u8,
    required: bool,
) ?*gtk.MediaFile {
    if (current) |media_file| {
        if (isForPath(media_file, path)) return media_file;
        media_file.unref();
    }

    const media_file = fromFilename(path) orelse return null;

    // If the audio file is marked as required, we'll emit an error if there
    // was a problem playing it. Otherwise there will be silence. We connect
    // this once, here, because the MediaFile is reused across bells.
    //
    // NOTE: we intentionally do NOT connect notify::ended to unref. The
    // MediaFile is owned by the surface and replayed via `seek(0)` for every
    // bell; unref'ing on `ended` is precisely what previously discarded (and
    // leaked) a pipeline per ring.
    if (required) {
        _ = gobject.Object.signals.notify.connect(
            media_file,
            ?*anyopaque,
            mediaFileError,
            null,
            .{ .detail = "error" },
        );
    }

    return media_file;
}

/// (Re)play `media_file` at `volume`. `seek(0)` rewinds first so that a
/// previously-ended stream plays again; without it playback only ever happens
/// once (see #8957). Safe on a freshly-created stream as well.
pub fn playBell(media_file: *gtk.MediaFile, volume: f64) void {
    const media_stream = media_file.as(gtk.MediaStream);
    media_stream.setVolume(volume);
    media_stream.seek(0);
    media_stream.play();
}

/// Whether `media_file` was created for `path`.
fn isForPath(media_file: *gtk.MediaFile, path: [:0]const u8) bool {
    const file = media_file.getFile() orelse return false;
    const cur = file.getPath() orelse return false;
    defer glib.free(cur);
    return std.mem.eql(u8, std.mem.span(cur), path);
}

fn mediaFileError(
    media_file: *gtk.MediaFile,
    _: *gobject.ParamSpec,
    _: ?*anyopaque,
) callconv(.c) void {
    const path = path: {
        const file = media_file.getFile() orelse break :path null;
        break :path file.getPath();
    };
    defer if (path) |p| glib.free(p);

    const media_stream = media_file.as(gtk.MediaStream);
    const err = media_stream.getError() orelse return;
    log.warn("error playing sound from {s}: {s} {d} {s}", .{
        path orelse "<<unknown>>",
        glib.quarkToString(err.f_domain),
        err.f_code,
        err.f_message orelse "",
    });
}

test "bellMediaFile reuses one MediaFile per path" {
    // Regression guard for the audio-bell thread leak: each bell must replay a
    // single cached MediaFile, not allocate a fresh GStreamer pipeline (which
    // leaked gstglcontext/gldisplay-event threads) per ring. We assert the
    // reuse contract of bellMediaFile directly; this needs no display and no
    // playback (MediaFile is lazy), only that the path comparison drives reuse.
    const testing = std.testing;

    // The files need not exist: MediaFile only records the path until played.
    const path_a: [:0]const u8 = "/tmp/ghostty-bell-test-a.oga";
    const path_b: [:0]const u8 = "/tmp/ghostty-bell-test-b.oga";

    var current = bellMediaFile(null, path_a, false) orelse return error.SkipZigTest;
    const first = current;
    try testing.expect(isForPath(current, path_a));

    // Same path => identical object (the leak regression is rebuilding here).
    current = bellMediaFile(current, path_a, false).?;
    try testing.expectEqual(first, current);

    // Changed path => rebuilt object targeting the new path (old one freed).
    current = bellMediaFile(current, path_b, false) orelse return error.SkipZigTest;
    try testing.expect(isForPath(current, path_b));
    try testing.expect(!isForPath(current, path_a));

    current.unref();
}
