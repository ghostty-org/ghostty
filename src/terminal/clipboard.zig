const std = @import("std");

/// The clipboard destination for a write.
pub const Location = enum(c_int) {
    standard = 0,
    selection = 1,
    primary = 2,
    _,
};

/// MIME types that name plain text across the platforms terminals run
/// on. We accept the union everywhere since serving text under any of these
/// names is harmless.
pub fn isTextMime(mime: []const u8) bool {
    const names: []const []const u8 = &.{
        "text/plain",
        "text/plain;charset=utf-8",
        "UTF8_STRING",
        "TEXT",
        "STRING",
    };
    for (names) |n| if (std.mem.eql(u8, mime, n)) return true;
    return false;
}

/// A single representation of clipboard data.
///
/// The MIME type and data are borrowed and only valid for the duration of a
/// clipboard write callback. Data is binary-safe.
pub const Content = struct {
    mime: []const u8,
    data: []const u8,
};

/// Requests content of a specific mime-type. For now this is used for
/// on-demand clipboard access since content can be large (particularly
/// non-text content), but it is generic so that this could handle other
/// mime-typed sources in the future like maybe drag-and-drop.
///
/// C: GhosttyMimeReader
pub const MimeReader = struct {
    /// Passed through to `read_fn`.
    ctx: ?*anyopaque = null,

    /// Write all the data of the representation named by `mime` to
    /// `sink`, in as many writes as is convenient. The mime and sink
    /// are borrowed, only valid for the duration of the call, and
    /// nothing written to the sink is retained, so the data may be
    /// borrowed from anywhere. Return error.ReadFailed if the data
    /// can't be produced and propagate error.WriteFailed from the
    /// sink.
    read_fn: *const fn (
        ctx: ?*anyopaque,
        mime: []const u8,
        sink: *std.Io.Writer,
    ) Error!void,

    pub const Error = error{
        /// The data could not be read.
        ReadFailed,
    } || std.Io.Writer.Error;

    pub fn read(
        self: MimeReader,
        mime: []const u8,
        sink: *std.Io.Writer,
    ) Error!void {
        return self.read_fn(self.ctx, mime, sink);
    }
};

/// A request from the running program to write a clipboard.
///
/// Writes are synchronous: the effect callback must answer through `reply`
/// before it returns, and the request (including its reply context) is
/// invalid afterwards. An embedder that needs user consent must block until
/// it has an answer; the VT stream waits with it. Protocols without a write
/// acknowledgement (OSC 52, OSC 1337 Copy) discard the reply.
///
/// Contents are borrowed and only valid for the duration of the callback.
/// An empty contents slice clears the destination.
pub const Write = struct {
    location: Location,
    contents: []const Content,

    /// Name of the writing program for permission prompts, if the
    /// protocol carries one. Empty otherwise.
    name: []const u8,

    /// True if the terminal already holds a session grant for this
    /// request (kitty clipboard protocol passwords). The embedder should
    /// skip any permission prompt and perform the write.
    granted: bool,

    /// True if the program supplied a session password, so the embedder
    /// may offer to remember the user's decision via
    /// Result.Success.remember. When false, remember is ignored.
    can_remember: bool,

    /// Terminal-owned reply state, only valid during the callback.
    reply_ctx: *anyopaque,
    reply_fn: *const fn (*anyopaque, Result) void,

    /// Answer the write. May be called at most once; later calls are
    /// ignored.
    pub fn reply(self: Write, result: Result) void {
        self.reply_fn(self.reply_ctx, result);
    }

    /// The status of a clipboard write reply.
    pub const Status = enum(c_int) {
        success = 0,
        denied = 1,
        unsupported = 2,
        busy = 3,
        invalid_data = 4,
        io_error = 5,
        _,
    };

    /// The reply to a clipboard write.
    pub const Result = union(enum) {
        /// The write was denied by policy or the user.
        denied,

        /// The embedder cannot write this clipboard.
        unsupported,

        /// The clipboard is temporarily unavailable.
        busy,

        /// One or more representations contain invalid data.
        invalid_data,

        /// Writing the clipboard failed.
        io_error,

        /// The write succeeded.
        success: Success,

        pub const Success = struct {
            /// Record a session grant so future requests from the same
            /// program skip the permission prompt. Only honored when the
            /// request set `can_remember`.
            remember: bool = false,
        };
    };
};

/// A request from the running program to read a clipboard.
///
/// Reads are synchronous: the effect callback must answer through `reply`
/// before it returns, and the request (including its reply context) is
/// invalid afterwards. An embedder that needs user consent must block until
/// it has an answer; the VT stream waits with it.
pub const Read = struct {
    location: Location,

    /// The MIME types the program wants, in order of preference. The
    /// reply should carry every requested representation the clipboard
    /// has; unrequested ones are ignored. Protocols that only carry text
    /// (OSC 52) request "text/plain".
    mimes: []const []const u8,

    /// The program also wants the list of MIME types available on the
    /// clipboard, delivered as Result.Success.available.
    list: bool,

    /// Name of the requesting program for permission prompts, if the
    /// protocol carries one. Empty otherwise.
    name: []const u8,

    /// True if the terminal already holds a session grant for this
    /// request (kitty clipboard protocol passwords). The embedder should
    /// skip any permission prompt and serve the read.
    ///
    /// Always false when mimes is empty: such a request is served
    /// without a prompt (kitty's targets-listing exemption), so the
    /// terminal never consults grants for it and a one-time password
    /// is preserved for the follow-up data read.
    granted: bool,

    /// True if the program supplied a session password, so the embedder
    /// may offer to remember the user's decision via
    /// Result.Success.remember. When false, remember is ignored.
    can_remember: bool,

    /// Terminal-owned reply state, only valid during the callback.
    ///
    /// The result is delivered through a call rather than returned so
    /// the terminal consumes it while the embedder's memory is still
    /// alive; a returned slice would have to outlive the callback.
    reply_ctx: *anyopaque,
    reply_fn: *const fn (*anyopaque, Result) void,

    /// Answer the read. May be called at most once; later calls are
    /// ignored. Result memory is borrowed only for the duration of this
    /// call.
    pub fn reply(self: Read, result: Result) void {
        self.reply_fn(self.reply_ctx, result);
    }

    /// The status of a clipboard read reply.
    pub const Status = enum(c_int) {
        success = 0,
        denied = 1,
        unsupported = 2,
        busy = 3,
        io_error = 4,
        _,
    };

    /// The reply to a clipboard read.
    pub const Result = union(enum) {
        /// The read was denied by policy or the user.
        denied,

        /// The embedder cannot read this clipboard.
        unsupported,

        /// The clipboard is temporarily unavailable.
        busy,

        /// Reading the clipboard failed.
        io_error,

        /// The read succeeded. All memory is borrowed for the duration
        /// of the reply call.
        success: Success,

        pub const Success = struct {
            /// Representations of the clipboard contents, one per
            /// requested MIME type the clipboard has. Protocols that
            /// carry a single text value use the first entry with a
            /// text MIME type (see isTextMime).
            contents: []const Content = &.{},

            /// All MIME types available on the clipboard. Only used when
            /// the request set `list`.
            available: []const []const u8 = &.{},

            /// Record a session grant so future requests from the same
            /// program skip the permission prompt. Only honored when the
            /// request set `can_remember`.
            remember: bool = false,
        };
    };
};

test isTextMime {
    const testing = std.testing;
    try testing.expect(isTextMime("text/plain"));
    try testing.expect(isTextMime("UTF8_STRING"));
    try testing.expect(!isTextMime("image/png"));
    try testing.expect(!isTextMime("."));
}
