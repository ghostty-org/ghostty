//! Pasting into a terminal.
//!
//! This is the single place that turns "the user pasted" into bytes for
//! the pty, applying the terminal's current state:
//!
//!   * Mode 5522 (Kitty clipboard protocol paste events) set, a
//!     user-initiated clipboard paste, and the embedder able to serve
//!     the program's follow-up clipboard read: send a paste event
//!     listing the clipboard's MIME types with a fresh one-time password
//!     and record a one-time read grant for it. No data is read.
//!   * Otherwise: write the first text representation, with unsafe bytes
//!     replaced (xterm behavior), framed per mode 2004 (bracketed paste)
//!     or with newlines converted to carriage returns if not.
//!
//! The precedence (5522 event, else 2004 framing, else plain) and the
//! safety rule live only here so every embedder of the terminal shares
//! one implementation.

const std = @import("std");
const Allocator = std.mem.Allocator;

const clipboard = @import("clipboard.zig");
const kitty_clipboard = @import("kitty/clipboard.zig");
const input_paste = @import("../input/paste.zig");
const Terminal = @import("Terminal.zig");

/// Why a paste happened. Only clipboard pastes may become paste
/// events, which is why only they carry a location: it's meaningless
/// for text insertion.
///
/// C: GhosttyPasteSource, flattened next to the location since C has
/// no tagged unions.
pub const Source = union(enum) {
    /// The user pasted from a clipboard: keybind, menu, middle click.
    /// The payload is the clipboard the contents came from.
    clipboard: clipboard.Location,

    /// Text inserted some other way: IME commit, drag and drop,
    /// scripted input.
    text,
};

/// A paste of clipboard contents into the terminal. What actually gets
/// written depends on terminal state; see `paste`.
pub const Request = struct {
    /// Why this paste happened, and for a clipboard paste, from which
    /// clipboard. Only a user-initiated clipboard paste may become a
    /// paste event; text insertion always writes text.
    source: Source = .{ .clipboard = .standard },

    /// The representations available. Borrowed only during the
    /// duration of the paste function call.
    contents: Contents,

    /// Write data that could inject commands (see `paste`). The usual
    /// flow is to call with false, confirm with the user on
    /// error.UnsafePaste, and call again with true.
    allow_unsafe: bool = false,
};

/// The representations available for a paste, in the embedder's
/// preferred order.
pub const Contents = union(enum) {
    /// Every representation already in memory. For text the embedder
    /// holds anyway (an IME commit, dropped text) or small clipboards.
    memory: []const clipboard.Content,

    /// Representations read on demand, so nothing is loaded that isn't
    /// pasted. This is the form for a real clipboard, whose non-text
    /// items may be huge.
    reader: Reader,

    /// The on-demand form: the MIME types available plus the reader
    /// that produces the data of any one of them.
    pub const Reader = struct {
        /// The MIME types available, in preferred order.
        mimes: []const []const u8,

        /// Produces the data of any entry of `mimes`, which is passed
        /// through to it as is. A paste reads at most once: the text
        /// representation being pasted, never anything else and never
        /// anything for a paste event. There is no requirement across
        /// paste calls, so a source that changes between an unsafe
        /// refusal and the embedder's confirmed retry simply pastes
        /// its current contents.
        read: clipboard.MimeReader,
    };

    /// The number of representations.
    pub fn len(self: Contents) usize {
        return switch (self) {
            .memory => |v| v.len,
            .reader => |v| v.mimes.len,
        };
    }

    /// The MIME type of representation `index`.
    pub fn mime(self: Contents, index: usize) []const u8 {
        return switch (self) {
            .memory => |v| v[index].mime,
            .reader => |v| v.mimes[index],
        };
    }
};

/// What a caller supplies to `paste`: the terminal state the decision
/// depends on, the session state an event records into, and the sink.
pub const Context = struct {
    /// The terminal whose modes decide the encoding.
    terminal: *const Terminal,

    /// Allocator for transient state: the buffered read and a paste
    /// event's grant. Must be the allocator `kitty_clipboard.grants`
    /// is freed with.
    alloc: Allocator,

    /// Receives the encoded text in chunks, or the event. Must be
    /// buffered (the encoder works in its buffer) and is not flushed
    /// by `paste`; the caller flushes once it returns.
    writer: *std.Io.Writer,

    /// Kitty clipboard protocol session state, or null if the embedder
    /// does not serve Kitty clipboard reads (`clipboard.Read`). A
    /// paste event is that protocol: it is only useful if the
    /// program's follow-up read can be answered, since otherwise the
    /// read would be refused and the user's paste would vanish. With
    /// null, `paste` always writes text.
    kitty_clipboard: ?KittyClipboard,

    pub const KittyClipboard = struct {
        /// Session grants. A paste event records its one-time password
        /// here so the program's follow-up read is served without a
        /// prompt.
        grants: *kitty_clipboard.Grants,

        /// Secure entropy for one-time passwords. See generateOtp for
        /// why there is no fallback when this has none.
        io: std.Io,
    };
};

pub const Error = Allocator.Error ||
    std.Io.RandomSecureError ||
    clipboard.MimeReader.Error ||
    error{
        /// The data could inject commands and allow_unsafe was false.
        UnsafePaste,
    };

/// Paste into the terminal, applying the terminal's current state as
/// described in the module docs. Returns true if anything was written
/// to `ctx.writer`: the encoded text or a paste event. False means
/// there was nothing to paste (no non-empty text representation).
///
/// The safety rule for a text paste (`input.paste.isSafeWith`): a
/// bracketed paste is unsafe only if it contains the bracket terminator
/// (CSI 201~); an unbracketed paste is unsafe if it contains a newline
/// or the terminator. Embedders wanting a stricter rule check
/// `input.paste.isSafe` themselves before calling. A paste event never
/// puts the data on the input stream, so the rule doesn't apply to it.
///
/// The contents are read at most once per call and buffered whole, so
/// the source needs no stability across reads. Nothing reaches the
/// writer until the read completed and the text passed the rule:
/// every error writes nothing, and a failed event records no grant.
pub fn paste(ctx: Context, req: Request) Error!bool {
    // If the source is a clipboard and mode 5522 is enabled and
    // the caller can handle kitty events, then do a kitty event.
    if (req.source == .clipboard and
        ctx.terminal.modes.get(.kitty_paste_events))
    {
        if (ctx.kitty_clipboard) |kitty| {
            try pasteKittyEvent(ctx, kitty, req);
            return true;
        }
    }

    // For non-Kitty paste events we can only accept text content.
    const index: usize = for (0..req.contents.len()) |i| {
        if (clipboard.isTextMime(req.contents.mime(i))) break i;
    } else return false;

    const opts: input_paste.Options = .fromTerminal(ctx.terminal);

    // In-memory contents are used directly to avoid a double copy but
    // reader-based contents are read into memory so we can do the unsafe
    // scan.
    var aw: std.Io.Writer.Allocating = .init(ctx.alloc);
    defer aw.deinit();
    const text: []const u8 = switch (req.contents) {
        .memory => |v| v[index].data,
        .reader => |v| text: {
            v.read.read(v.mimes[index], &aw.writer) catch |err| switch (err) {
                // An allocating writer only fails to allocate.
                error.WriteFailed => return error.OutOfMemory,
                error.ReadFailed => |e| return e,
            };
            break :text aw.writer.buffered();
        },
    };
    if (text.len == 0) return false;
    if (!req.allow_unsafe and !input_paste.isSafeWith(
        text,
        opts,
    )) return error.UnsafePaste;

    // The text is copied exactly once per chunk, into the writer,
    // where the encoder strips and converts it in place.
    try input_paste.encodeWriter(ctx.writer, text, opts);
    return true;
}

fn pasteKittyEvent(
    ctx: Context,
    kitty: Context.KittyClipboard,
    req: Request,
) Error!void {
    const otp = try kitty_clipboard.generateOtp(kitty.io);

    // Every representation is listed, never read. The listing is
    // bounded; a clipboard with more types than that is not a thing.
    var mimes_buf: [kitty_clipboard.max_listing_mimes][]const u8 = undefined;
    const mimes_len = @min(req.contents.len(), mimes_buf.len);
    for (mimes_buf[0..mimes_len], 0..) |*mime, i| mime.* = req.contents.mime(i);

    // The grant is recorded before the event can reach the program,
    // and revoked if the event fails to be written so a failure never
    // leaves a grant for an event that was never sent. Using a
    // one-time grant consumes it, which is the revocation.
    try kitty.grants.grant(ctx.alloc, &otp, .read, true);
    errdefer _ = kitty.grants.use(ctx.alloc, &otp, .read);

    try (kitty_clipboard.PasteEvent{
        // The protocol only distinguishes the clipboard from the
        // primary selection, so both non-standard locations report as
        // primary. Only a clipboard paste gets here; see `paste`.
        .primary = req.source.clipboard != .standard,
        .pw = &otp,
        .available = mimes_buf[0..mimes_len],
    }).encode(ctx.writer);
}

test {
    // The behavior is tested end to end through the stream handler
    // (stream_terminal.zig), which is the primary caller.
    std.testing.refAllDecls(@This());
}
