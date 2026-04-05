const build_config = @import("../build_config.zig");

/// ContentScale is the ratio between the current DPI and the platform's
/// default DPI. This is used to determine how much certain rendered elements
/// need to be scaled up or down.
pub const ContentScale = struct {
    x: f32,
    y: f32,
};

/// The size of the surface in pixels.
pub const SurfaceSize = struct {
    width: u32,
    height: u32,

    pub fn eql(self: *const SurfaceSize, other: *const SurfaceSize) bool {
        return self.width == other.width and self.height == other.height;
    }
};

/// The position of the cursor in pixels.
pub const CursorPos = struct {
    x: f32,
    y: f32,
};

/// Input Method Editor (IME) position.
pub const IMEPos = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

/// The clipboard type.
///
/// If this is changed, you must also update ghostty.h
pub const Clipboard = enum(Backing) {
    standard = 0, // ctrl+c/v
    selection = 1,
    primary = 2,

    // Our backing isn't is as small as we can in Zig, but a full
    // C int if we're binding to C APIs.
    const Backing = switch (build_config.app_runtime) {
        .gtk => c_int,
        else => u2,
    };

    /// Make this a valid gobject if we're in a GTK environment.
    pub const getGObjectType = switch (build_config.app_runtime) {
        .gtk => @import("gobject").ext.defineEnum(
            Clipboard,
            .{ .name = "GhosttyApprtClipboard" },
        ),

        .none => void,
    };
};

pub const ClipboardContent = struct {
    mime: [:0]const u8,
    data: [:0]const u8,
};

pub const ClipboardRequestType = enum(u8) {
    paste,
    osc_52_read,
    osc_52_write,
    kitty_mime_list,
    kitty_mime_read,
};

/// Clipboard request. This is used to request clipboard contents and must
/// be sent as a response to a ClipboardRequest event.
pub const ClipboardRequest = union(ClipboardRequestType) {
    /// A direct paste of clipboard contents.
    paste: void,

    /// A request to read clipboard contents via OSC 52.
    osc_52_read: Clipboard,

    /// A request to write clipboard contents via OSC 52.
    osc_52_write: Clipboard,

    /// A request to list available MIME types on the clipboard for the
    /// kitty clipboard protocol (OSC 5522, mode 5522). The apprt should
    /// complete this request with a newline-separated list of MIME types.
    kitty_mime_list: Clipboard,

    /// A request to read a specific MIME type from the clipboard for the
    /// kitty clipboard protocol. The apprt should complete this request
    /// with the base64-encoded data for the requested MIME type.
    kitty_mime_read: KittyMimeRead,

    pub const KittyMimeRead = struct {
        pub const mime_max_len = 256;

        clipboard: Clipboard,
        /// The requested MIME type, null-terminated.
        mime: [mime_max_len:0]u8,

        pub fn init(clipboard: Clipboard, mime: []const u8) KittyMimeRead {
            var result: KittyMimeRead = .{
                .clipboard = clipboard,
                .mime = [_:0]u8{0} ** mime_max_len,
            };
            const len = @min(mime.len, mime_max_len);
            @memcpy(result.mime[0..len], mime[0..len]);
            return result;
        }

        test init {
            const testing = @import("std").testing;
            const mem = @import("std").mem;

            // Basic MIME type
            {
                const r = KittyMimeRead.init(.standard, "text/plain");
                try testing.expectEqual(Clipboard.standard, r.clipboard);
                try testing.expectEqualStrings("text/plain", mem.sliceTo(&r.mime, 0));
            }

            // Image MIME type
            {
                const r = KittyMimeRead.init(.standard, "image/png");
                try testing.expectEqualStrings("image/png", mem.sliceTo(&r.mime, 0));
            }

            // Empty MIME
            {
                const r = KittyMimeRead.init(.standard, "");
                try testing.expectEqualStrings("", mem.sliceTo(&r.mime, 0));
            }

            // Exactly at the limit (boundary)
            {
                const long = "a" ** mime_max_len;
                const r = KittyMimeRead.init(.standard, long);
                try testing.expectEqualStrings(long, mem.sliceTo(&r.mime, 0));
                try testing.expectEqual(@as(u8, 0), r.mime[mime_max_len]);
            }

            // Over the limit (truncation)
            {
                const overlong = "x" ** (mime_max_len + 50);
                const r = KittyMimeRead.init(.standard, overlong);
                try testing.expectEqual(@as(usize, mime_max_len), mem.sliceTo(&r.mime, 0).len);
                try testing.expectEqual(@as(u8, 0), r.mime[mime_max_len]);
            }

            // Real Office MIME types fit
            {
                const xlsx = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
                const r = KittyMimeRead.init(.standard, xlsx);
                try testing.expectEqualStrings(xlsx, mem.sliceTo(&r.mime, 0));
            }
        }
    };

    /// Make this a valid gobject if we're in a GTK environment.
    pub const getGObjectType = switch (build_config.app_runtime) {
        .gtk => @import("gobject").ext.defineBoxed(
            ClipboardRequest,
            .{ .name = "GhosttyClipboardRequest" },
        ),

        .none => void,
    };
};

/// The color scheme in use (light vs dark).
pub const ColorScheme = enum(u2) {
    light = 0,
    dark = 1,
};

/// Selection information
pub const Selection = struct {
    /// Top-left point of the selection in the viewport in scaled
    /// window pixels. (0,0) is the top-left of the window.
    tl_x_px: f64,
    tl_y_px: f64,

    /// The offset of the selection start in cells from the top-left
    /// of the viewport.
    ///
    /// This is a strange metric but its used by macOS.
    offset_start: u32,
    offset_len: u32,
};
