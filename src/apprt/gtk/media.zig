const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;

const log = std.log.scoped(.gtk_media);

const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

pub fn fromFilename(path: [:0]const u8) ?*gtk.MediaFile {
    assert(std.fs.path.isAbsolute(path));
    std.fs.accessAbsolute(path, .{ .mode = .read_only }) catch |err| {
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

pub fn playMediaFile(media_file: *gtk.MediaFile, volume: f64, required: bool) void {
    // If the audio file is marked as required, we'll emit an error if
    // there was a problem playing it. Otherwise there will be silence.
    if (required) {
        _ = gobject.Object.signals.notify.connect(
            media_file,
            ?*anyopaque,
            mediaFileError,
            null,
            .{ .detail = "error" },
        );
    }

    // Watch for the "ended" signal so that we can clean up after
    // ourselves.
    _ = gobject.Object.signals.notify.connect(
        media_file,
        ?*anyopaque,
        mediaFileEnded,
        null,
        .{ .detail = "ended" },
    );

    const media_stream = media_file.as(gtk.MediaStream);
    media_stream.setVolume(volume);
    media_stream.play();
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

fn mediaFileEnded(
    media_file: *gtk.MediaFile,
    _: *gobject.ParamSpec,
    _: ?*anyopaque,
) callconv(.c) void {
    media_file.unref();
}
