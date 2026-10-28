const std = @import("std");
const build_config = @import("../build_config.zig");
const terminal = @import("../terminal/main.zig");

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
    kitty_read,
    kitty_write,
    list,
};

/// The result of starting a clipboard read request. This only reports
/// facts about the clipboard; how each state is answered on the wire
/// (if at all) is up to the protocol handling of the requester.
///
/// If this is changed, you must also update ghostty.h
pub const ClipboardReadResult = enum(c_int) {
    /// The request was started and will be completed asynchronously
    /// via the core surface completeClipboardRequest API.
    started = 0,

    /// The clipboard exists but has no contents the apprt can serve
    /// (e.g. no text-like data). The request was not started.
    unavailable = 1,

    /// The clipboard itself can't be read (e.g. a primary selection on
    /// a platform without one). The request was not started.
    unsupported = 2,
};

/// Clipboard request. This is used to request clipboard contents and must
/// be sent as a response to a ClipboardRequest event.
pub const ClipboardRequest = union(ClipboardRequestType) {
    /// A direct paste of clipboard contents.
    paste: Clipboard,

    /// A request to read clipboard contents via OSC 52.
    osc_52_read: Clipboard,

    /// A request to write clipboard contents via OSC 52.
    osc_52_write: Clipboard,

    /// A request to read clipboard contents via the Kitty clipboard
    /// protocol (OSC 5522).
    kitty_read: *KittyRead,

    /// A request to write clipboard contents via the Kitty clipboard
    /// protocol (OSC 5522), carrying a fully committed transaction.
    kitty_write: *KittyWrite,

    /// A request to list the available clipboard MIME types without
    /// reading any of their data.
    list: Clipboard,

    /// State for one in-flight Kitty clipboard protocol read. This is
    /// created on the IO thread and completed on the app thread, so it
    /// owns all of its memory: everything, including the struct itself,
    /// is allocated from the arena.
    pub const KittyRead = struct {
        arena: std.heap.ArenaAllocator,

        /// The clipboard being read. The protocol can only name the
        /// standard clipboard or the primary selection.
        location: Clipboard,

        /// The requested MIME types in request order, already capped at
        /// terminal.kitty.clipboard.max_read_mimes by the sender. Only
        /// these representations may be served in the response. The
        /// values are sentinel-terminated so they can cross a C apprt
        /// boundary without copies.
        mimes: []const [:0]const u8,

        /// True when the targets ('.') listing was requested.
        list: bool,

        /// The sanitized request id, echoed in every response packet.
        id: []const u8,

        /// The effective session password, empty when the request had
        /// none. A non-empty password means the user's decision may be
        /// remembered as a session grant.
        pw: []const u8,

        /// The human friendly name of the requesting program, shown in
        /// permission prompts. Empty when absent. Sentinel-terminated
        /// so it can cross a C apprt boundary without copies.
        name: [:0]const u8,

        /// True when a stored session grant already covers this
        /// request, so any permission prompt is skipped.
        granted: bool,

        /// The response terminator, matching the request's.
        terminator: terminal.osc.Terminator,

        pub fn destroy(self: *KittyRead) void {
            // The struct itself lives in the arena, so move the arena
            // out before tearing it down.
            var arena = self.arena;
            arena.deinit();
        }
    };

    /// State for one committed Kitty clipboard protocol write
    /// transaction. Like KittyRead, this is created on the IO thread
    /// and completed on the app thread, so everything, including the
    /// struct itself, is allocated from the arena.
    pub const KittyWrite = struct {
        arena: std.heap.ArenaAllocator,

        /// The clipboard being written. The protocol can only name the
        /// standard clipboard or the primary selection.
        location: Clipboard,

        /// The committed representations. These are the authoritative
        /// contents of the write: completions apply these rather than
        /// any contents echoed back by the apprt. The values are
        /// sentinel-terminated so they can cross a C apprt boundary
        /// without copies; data is binary-safe via its length.
        contents: []const ClipboardContent,

        /// The sanitized request id, echoed in every response packet.
        id: []const u8,

        /// The effective session password, empty when the request had
        /// none. A non-empty password means the user's decision may be
        /// remembered as a session grant.
        pw: []const u8,

        /// The human friendly name of the requesting program, shown in
        /// permission prompts. Empty when absent. Sentinel-terminated
        /// so it can cross a C apprt boundary without copies.
        name: [:0]const u8,

        /// True when a stored session grant already covers this
        /// request, so any permission prompt is skipped.
        granted: bool,

        /// The response terminator, matching the request's.
        terminator: terminal.osc.Terminator,

        pub fn destroy(self: *KittyWrite) void {
            // The struct itself lives in the arena, so move the arena
            // out before tearing it down.
            var arena = self.arena;
            arena.deinit();
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
