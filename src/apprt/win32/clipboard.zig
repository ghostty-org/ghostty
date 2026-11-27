//! Reading and writing the Windows clipboard.
//!
//! Text is stored the way every Windows program expects it. Images are
//! stored as PNG under the registered format name "PNG", which most image
//! programs also use. Other kinds of content are not supported.
const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../../terminal/main.zig");
const c = @import("c.zig");

extern "user32" fn RegisterClipboardFormatW(name: [*:0]const u16) callconv(.c) u32;
extern "user32" fn IsClipboardFormatAvailable(format: u32) callconv(.c) c_int;
extern "kernel32" fn GlobalSize(mem: c.Handle) callconv(.c) usize;

pub const png_mime = "image/png";
pub const text_mime = "text/plain";

pub const Item = struct {
    mime: []const u8,
    data: []const u8,
};

pub const Error = error{ ClipboardUnavailable, NoContent } || Allocator.Error;

fn pngFormat() u32 {
    return RegisterClipboardFormatW(c.utf16Literal("PNG"));
}

/// The kinds of content on the clipboard that can be read, as MIME types.
/// The result is a slice of `buffer`, filled with fixed strings.
pub fn availableMimes(buffer: [][]const u8) []const []const u8 {
    var count: usize = 0;
    if (count < buffer.len and IsClipboardFormatAvailable(c.CF_UNICODETEXT) != 0) {
        buffer[count] = text_mime;
        count += 1;
    }
    if (count < buffer.len and IsClipboardFormatAvailable(pngFormat()) != 0) {
        buffer[count] = png_mime;
        count += 1;
    }
    return buffer[0..count];
}

/// The clipboard's text. The caller frees it.
pub fn readText(alloc: Allocator) Error![]u8 {
    if (c.OpenClipboard(null) == 0) return error.ClipboardUnavailable;
    defer _ = c.CloseClipboard();

    const handle = c.GetClipboardData(c.CF_UNICODETEXT) orelse return error.NoContent;
    const locked = c.GlobalLock(handle) orelse return error.ClipboardUnavailable;
    defer _ = c.GlobalUnlock(handle);

    const wide: [*:0]const u16 = @ptrCast(@alignCast(locked));
    return std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(wide)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.NoContent,
    };
}

/// The clipboard's PNG image. The caller frees it.
fn readPng(alloc: Allocator) Error![]u8 {
    if (c.OpenClipboard(null) == 0) return error.ClipboardUnavailable;
    defer _ = c.CloseClipboard();

    const handle = c.GetClipboardData(pngFormat()) orelse return error.NoContent;
    const locked = c.GlobalLock(handle) orelse return error.ClipboardUnavailable;
    defer _ = c.GlobalUnlock(handle);

    const size = GlobalSize(handle);
    return alloc.dupe(u8, locked[0..size]);
}

/// The clipboard's content in the kind of the given MIME type, or null when
/// it has none of that kind. The caller frees it.
pub fn readMime(alloc: Allocator, mime: []const u8) Allocator.Error!?[]u8 {
    const result = if (terminal.clipboard.isTextMime(mime))
        readText(alloc)
    else if (std.mem.eql(u8, mime, png_mime))
        readPng(alloc)
    else
        return null;

    return result catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

/// Put content on the clipboard, replacing what is there. Kinds that are not
/// supported are skipped, and if nothing can be stored the clipboard is left
/// as it was.
pub fn write(alloc: Allocator, owner: c.Handle, items: []const Item) Error!void {
    var text: ?[]const u8 = null;
    var png: ?[]const u8 = null;
    for (items) |item| {
        if (text == null and terminal.clipboard.isTextMime(item.mime)) text = item.data;
        if (png == null and std.mem.eql(u8, item.mime, png_mime)) png = item.data;
    }
    if (text == null and png == null) return error.NoContent;

    if (c.OpenClipboard(owner) == 0) return error.ClipboardUnavailable;
    defer _ = c.CloseClipboard();
    _ = c.EmptyClipboard();

    if (text) |value| {
        // Text that is not valid UTF-8 cannot be stored as Windows text.
        const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NoContent,
        };
        defer alloc.free(wide);
        try store(c.CF_UNICODETEXT, std.mem.sliceAsBytes(wide.ptr[0 .. wide.len + 1]));
    }
    if (png) |value| try store(pngFormat(), value);
}

/// Hand bytes to the clipboard under a format. Windows owns the memory once
/// it has accepted it.
fn store(format: u32, bytes: []const u8) Error!void {
    const handle = c.GlobalAlloc(c.GMEM_MOVEABLE, @max(bytes.len, 1)) orelse return error.OutOfMemory;
    var accepted = false;
    defer if (!accepted) {
        _ = c.GlobalFree(handle);
    };

    const locked = c.GlobalLock(handle) orelse return error.ClipboardUnavailable;
    @memcpy(locked[0..bytes.len], bytes);
    _ = c.GlobalUnlock(handle);

    if (c.SetClipboardData(format, handle) == null) return error.ClipboardUnavailable;
    accepted = true;
}
