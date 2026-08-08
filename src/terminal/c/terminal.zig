const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const build_options = @import("terminal_options");
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
pub const ZigTerminal = @import("../Terminal.zig");
const Action = @import("../stream.zig").Action;
const osc = @import("../osc.zig");
const Stream = @import("../stream_terminal.zig").Stream;
const Screen = @import("../Screen.zig");
const ScreenSet = @import("../ScreenSet.zig");
const PageList = @import("../PageList.zig");
const apc = @import("../apc.zig");
const kitty = @import("../kitty/key.zig");
const kitty_gfx_c = @import("kitty_graphics.zig");
const modes = @import("../modes.zig");
const point = @import("../point.zig");
const size = @import("../size.zig");
const device_attributes = @import("../device_attributes.zig");
const device_status = @import("../device_status.zig");
const size_report = @import("../size_report.zig");
const cell_c = @import("cell.zig");
const row_c = @import("row.zig");
const grid_ref_c = @import("grid_ref.zig");
const grid_ref_tracked_c = @import("grid_ref_tracked.zig");
const selection_c = @import("selection.zig");
const style_c = @import("style.zig");
const color = @import("../color.zig");
const clipboard = @import("../clipboard.zig");
const c_io = @import("io.zig");
const snapshot_core = @import("../snapshot/main.zig");
const Result = @import("result.zig").Result;
const assert = @import("quirks").inlineAssert;

const Handler = @import("../stream_terminal.zig").Handler;

const max_path_bytes = if (builtin.os.tag == .freestanding) 4096 else std.fs.max_path_bytes;

const log = std.log.scoped(.terminal_c);

/// C terminals do not retain replay bytes unless the embedding application
/// opts in through `GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES`.
pub const default_continuation_max_bytes: usize = 0;

/// Owns the `std.Io` implementation retained by every C terminal.
///
/// Snapshot decoding creates this before the native terminal exists and
/// transfers it into the final C wrapper after READY.
pub const Io = struct {
    impl: Impl,

    /// Platform-specific storage backing the public `std.Io` value.
    const Impl = if (builtin.os.tag != .freestanding)
        *std.Io.Threaded
    else
        void;

    /// Allocation failures possible while constructing an I/O owner.
    pub const Error = error{OutOfMemory};

    /// Allocate the native I/O implementation when the platform requires it.
    pub fn init(alloc: std.mem.Allocator) Error!Io {
        if (comptime builtin.os.tag == .freestanding) return .{ .impl = {} };

        const ptr = alloc.create(std.Io.Threaded) catch
            return error.OutOfMemory;
        ptr.* = .init_single_threaded;
        return .{ .impl = ptr };
    }

    /// Return the value passed to native terminal construction and decoding.
    pub fn io(self: Io) std.Io {
        if (comptime builtin.os.tag == .freestanding) {
            return std.Io.failing;
        }
        return self.impl.io();
    }

    /// Release an I/O implementation that has not already been transferred.
    pub fn deinit(self: Io, alloc: std.mem.Allocator) void {
        if (comptime builtin.os.tag != .freestanding) {
            self.impl.deinit();
            alloc.destroy(self.impl);
        }
    }
};

/// Wrapper around ZigTerminal that tracks additional state for C API usage,
/// such as the persistent VT stream needed to handle escape sequences split
/// across multiple vt_write calls.
const TerminalWrapper = struct {
    terminal: *ZigTerminal,
    /// C construction has no I/O argument, so the wrapper retains the owner
    /// created by `new` or transferred from snapshot decoding until `free`.
    /// Freestanding owners contain no native allocation and expose failing I/O.
    io: Io,
    /// We also need to store a temp dir path for some operations (e.g., kitty
    /// graphics). This provides stable storage for the API calls.
    tmp_dir_path: [max_path_bytes]u8,
    stream: Stream,
    effects: Effects = .{},
    tracked_grid_refs: std.AutoArrayHashMapUnmanaged(*grid_ref_tracked_c.TrackedGridRef, void) = .{},

    /// Fetches a `TerminalWrapper` reference from a `Handler`.
    fn fromHandler(handler: *Handler) *TerminalWrapper {
        const stream_ptr: *Stream = @fieldParentPtr("handler", handler);
        return @alignCast(@fieldParentPtr("stream", stream_ptr));
    }
};

/// A single MIME representation in a clipboard write.
///
/// C: GhosttyClipboardContent
pub const ClipboardContent = extern struct {
    mime: lib.String,
    data: lib.String,
};

/// A protocol-neutral request to replace or clear clipboard contents.
///
/// C: GhosttyClipboardWrite
pub const ClipboardWrite = extern struct {
    size: usize,
    location: clipboard.Location,
    contents: ?[*]const ClipboardContent,
    contents_len: usize,
};

/// A request to show a desktop notification.
///
/// C: GhosttyTerminalDesktopNotification
pub const DesktopNotification = extern struct {
    size: usize,
    title: lib.String,
    body: lib.String,
};

/// C: GhosttyTerminalProgressState
pub const ProgressState = osc.Command.ProgressReport.State;

/// A progress report emitted by the running program.
///
/// C: GhosttyTerminalProgressReport
pub const ProgressReport = extern struct {
    size: usize,
    state: ProgressState,
    progress: i8,
};

/// A terminal mode and boolean value used for mode configuration.
///
/// C: GhosttyTerminalModeConfig
pub const ModeConfig = extern struct {
    mode: modes.ModeTag.Backing,
    value: bool,

    fn toMode(self: ModeConfig) ?modes.Mode {
        const tag: modes.ModeTag = @bitCast(self.mode);
        return modes.modeFromInt(tag.value, tag.ansi);
    }
};

/// C callback state for terminal effects. Trampolines are always
/// installed on the stream handler; they check these fields and
/// no-op when the corresponding callback is null.
const Effects = struct {
    userdata: ?*anyopaque = null,
    write_pty: ?WritePtyFn = null,
    bell: ?BellFn = null,
    color_scheme: ?ColorSchemeFn = null,
    desktop_notification: ?DesktopNotificationFn = null,
    device_attributes_cb: ?DeviceAttributesFn = null,
    enquiry: ?EnquiryFn = null,
    xtversion: ?XtversionFn = null,
    title_changed: ?TitleChangedFn = null,
    pwd_changed: ?PwdChangedFn = null,
    progress_report: ?ProgressReportFn = null,
    size_cb: ?SizeFn = null,
    clipboard_write: ?ClipboardWriteFn = null,

    /// Scratch buffer for DA1 feature codes. The device attributes
    /// trampoline converts C feature codes into this buffer and returns
    /// a slice pointing into it. Storing it here ensures the slice
    /// remains valid after the trampoline returns, since the caller
    /// (`reportDeviceAttributes`) reads it before any re-entrant call.
    da_features_buf: [64]device_attributes.Primary.Feature = undefined,

    /// C function pointer type for the write_pty callback.
    pub const WritePtyFn = *const fn (Terminal, ?*anyopaque, [*]const u8, usize) callconv(lib.calling_conv) void;

    /// C function pointer type for the bell callback.
    pub const BellFn = *const fn (Terminal, ?*anyopaque) callconv(lib.calling_conv) void;

    /// C function pointer type for the color_scheme callback.
    /// Returns true and fills out_scheme if a color scheme is available,
    /// or returns false to silently ignore the query.
    pub const ColorSchemeFn = *const fn (Terminal, ?*anyopaque, *device_status.ColorScheme) callconv(lib.calling_conv) bool;

    /// C function pointer type for the enquiry callback.
    /// Returns the response bytes. The memory must remain valid
    /// until the callback returns.
    pub const EnquiryFn = *const fn (Terminal, ?*anyopaque) callconv(lib.calling_conv) lib.String;

    /// C function pointer type for the xtversion callback.
    /// Returns the version string (e.g. "ghostty 1.2.3"). The memory
    /// must remain valid until the callback returns. An empty string
    /// (len=0) causes the default "libghostty" to be reported.
    pub const XtversionFn = *const fn (Terminal, ?*anyopaque) callconv(lib.calling_conv) lib.String;

    /// C function pointer type for the clipboard_write callback. The request
    /// and its contents are borrowed and only valid for the callback duration.
    pub const ClipboardWriteFn = *const fn (Terminal, ?*anyopaque, *const ClipboardWrite) callconv(lib.calling_conv) clipboard.WriteResult;

    /// C function pointer type for the desktop_notification callback. The
    /// request and its strings are borrowed for the callback duration.
    pub const DesktopNotificationFn = *const fn (Terminal, ?*anyopaque, *const DesktopNotification) callconv(lib.calling_conv) void;

    /// C function pointer type for the title_changed callback.
    pub const TitleChangedFn = *const fn (Terminal, ?*anyopaque) callconv(lib.calling_conv) void;

    /// C function pointer type for the pwd_changed callback.
    pub const PwdChangedFn = *const fn (Terminal, ?*anyopaque) callconv(lib.calling_conv) void;

    /// C function pointer type for the progress_report callback.
    pub const ProgressReportFn = *const fn (Terminal, ?*anyopaque, *const ProgressReport) callconv(lib.calling_conv) void;

    /// C function pointer type for the size callback.
    /// Returns true and fills out_size if size is available,
    /// or returns false to silently ignore the query.
    pub const SizeFn = *const fn (Terminal, ?*anyopaque, *size_report.Size) callconv(lib.calling_conv) bool;

    /// C function pointer type for the device_attributes callback.
    /// Returns true and fills out_attrs if attributes are available,
    /// or returns false to silently ignore the query.
    pub const DeviceAttributesFn = *const fn (Terminal, ?*anyopaque, *CDeviceAttributes) callconv(lib.calling_conv) bool;

    /// C-compatible device attributes struct.
    /// C: GhosttyDeviceAttributes
    pub const CDeviceAttributes = extern struct {
        primary: Primary,
        secondary: Secondary,
        tertiary: Tertiary,

        pub const Primary = extern struct {
            conformance_level: u16,
            features: [64]u16,
            num_features: usize,
        };

        pub const Secondary = extern struct {
            device_type: u16,
            firmware_version: u16,
            rom_cartridge: u16,
        };

        pub const Tertiary = extern struct {
            unit_id: u32,
        };
    };

    fn writePtyTrampoline(handler: *Handler, data: [:0]const u8) void {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.write_pty orelse return;
        func(@ptrCast(wrapper), wrapper.effects.userdata, data.ptr, data.len);
    }

    fn bellTrampoline(handler: *Handler) void {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.bell orelse return;
        func(@ptrCast(wrapper), wrapper.effects.userdata);
    }

    fn clipboardWriteTrampoline(handler: *Handler, write: clipboard.Write) clipboard.WriteResult {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.clipboard_write orelse return .unsupported;

        // Most protocols currently produce one representation, so keep that
        // path allocation-free while supporting arbitrary multi-MIME writes.
        var stack_contents: [4]ClipboardContent = undefined;
        const contents: []ClipboardContent = if (write.contents.len <= stack_contents.len)
            stack_contents[0..write.contents.len]
        else
            wrapper.terminal.gpa().alloc(ClipboardContent, write.contents.len) catch
                return .io_error;
        defer if (write.contents.len > stack_contents.len)
            wrapper.terminal.gpa().free(contents);

        for (contents, write.contents) |*c_content, content| {
            c_content.* = .{
                .mime = .{
                    .ptr = content.mime.ptr,
                    .len = content.mime.len,
                },
                .data = .{
                    .ptr = content.data.ptr,
                    .len = content.data.len,
                },
            };
        }

        const request: ClipboardWrite = .{
            .size = @sizeOf(ClipboardWrite),
            .location = write.location,
            .contents = if (contents.len > 0) contents.ptr else null,
            .contents_len = contents.len,
        };
        return func(@ptrCast(wrapper), wrapper.effects.userdata, &request);
    }

    fn desktopNotificationTrampoline(
        handler: *Handler,
        notification: Action.ShowDesktopNotification,
    ) void {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.desktop_notification orelse return;
        const request: DesktopNotification = .{
            .size = @sizeOf(DesktopNotification),
            .title = .{
                .ptr = notification.title.ptr,
                .len = notification.title.len,
            },
            .body = .{
                .ptr = notification.body.ptr,
                .len = notification.body.len,
            },
        };
        func(@ptrCast(wrapper), wrapper.effects.userdata, &request);
    }

    fn colorSchemeTrampoline(handler: *Handler) ?device_status.ColorScheme {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.color_scheme orelse return null;
        var scheme: device_status.ColorScheme = undefined;
        if (func(@ptrCast(wrapper), wrapper.effects.userdata, &scheme)) return scheme;
        return null;
    }

    fn deviceAttributesTrampoline(handler: *Handler) device_attributes.Attributes {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.device_attributes_cb orelse return .{};

        // Get our attributes from the callback.
        var c_attrs: CDeviceAttributes = undefined;
        if (!func(@ptrCast(wrapper), wrapper.effects.userdata, &c_attrs)) return .{};

        // Note below we use a lot of enumFromInt but its always safe
        // because all our types are non-exhaustive enums.

        const n: usize = @min(c_attrs.primary.num_features, 64);
        for (0..n) |i| wrapper.effects.da_features_buf[i] = @enumFromInt(c_attrs.primary.features[i]);

        return .{
            .primary = .{
                .conformance_level = @enumFromInt(c_attrs.primary.conformance_level),
                .features = wrapper.effects.da_features_buf[0..n],
            },
            .secondary = .{
                .device_type = @enumFromInt(c_attrs.secondary.device_type),
                .firmware_version = c_attrs.secondary.firmware_version,
                .rom_cartridge = c_attrs.secondary.rom_cartridge,
            },
            .tertiary = .{
                .unit_id = c_attrs.tertiary.unit_id,
            },
        };
    }

    fn enquiryTrampoline(handler: *Handler) []const u8 {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.enquiry orelse return "";
        const result = func(@ptrCast(wrapper), wrapper.effects.userdata);
        if (result.len == 0) return "";
        return result.ptr[0..result.len];
    }

    fn xtversionTrampoline(handler: *Handler) []const u8 {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.xtversion orelse return "";
        const result = func(@ptrCast(wrapper), wrapper.effects.userdata);
        if (result.len == 0) return "";
        return result.ptr[0..result.len];
    }

    fn titleChangedTrampoline(handler: *Handler) void {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.title_changed orelse return;
        func(@ptrCast(wrapper), wrapper.effects.userdata);
    }

    fn pwdChangedTrampoline(handler: *Handler) void {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.pwd_changed orelse return;
        func(@ptrCast(wrapper), wrapper.effects.userdata);
    }

    fn progressReportTrampoline(
        handler: *Handler,
        report: osc.Command.ProgressReport,
    ) void {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.progress_report orelse return;
        const c_report: ProgressReport = .{
            .size = @sizeOf(ProgressReport),
            .state = @enumFromInt(@intFromEnum(report.state)),
            .progress = if (report.progress) |value| @intCast(value) else -1,
        };
        func(@ptrCast(wrapper), wrapper.effects.userdata, &c_report);
    }

    fn sizeTrampoline(handler: *Handler) ?size_report.Size {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.size_cb orelse return null;
        var s: size_report.Size = undefined;
        if (func(@ptrCast(wrapper), wrapper.effects.userdata, &s)) return s;
        return null;
    }
};

/// C: GhosttyTerminal
pub const Terminal = ?*TerminalWrapper;

/// C: GhosttyTerminalCompressionMode
pub const CompressionMode = ZigTerminal.CompressionMode;

/// C: GhosttyTerminalCompressionResult
pub const CompressionResult = ZigTerminal.CompressionResult;

pub fn zigTerminal(terminal_: Terminal) ?*ZigTerminal {
    return (terminal_ orelse return null).terminal;
}

/// Attach the persistent C stream and I/O owner to a heap-stable terminal.
/// The caller retains ownership of both inputs if wrapper allocation fails.
fn wrap(
    alloc: std.mem.Allocator,
    t: *ZigTerminal,
    io: Io,
    continuation_max_bytes: usize,
) error{OutOfMemory}!Terminal {
    const wrapper = alloc.create(TerminalWrapper) catch
        return error.OutOfMemory;

    // Trampolines are always installed so setting C callbacks later takes
    // effect immediately.
    var handler: Stream.Handler = t.vtHandler();
    handler.effects = .{
        .write_pty = &Effects.writePtyTrampoline,
        .bell = &Effects.bellTrampoline,
        .color_scheme = &Effects.colorSchemeTrampoline,
        .desktop_notification = &Effects.desktopNotificationTrampoline,
        .device_attributes = &Effects.deviceAttributesTrampoline,
        .enquiry = &Effects.enquiryTrampoline,
        .xtversion = &Effects.xtversionTrampoline,
        .title_changed = &Effects.titleChangedTrampoline,
        .pwd_changed = &Effects.pwdChangedTrampoline,
        .progress_report = &Effects.progressReportTrampoline,
        .size = &Effects.sizeTrampoline,
        .clipboard_write = &Effects.clipboardWriteTrampoline,
    };

    wrapper.* = .{
        .terminal = t,
        .io = io,
        .tmp_dir_path = undefined,
        .stream = Stream.init(.{
            .allocator = alloc,
            .handler = handler,
            .continuation_max_bytes = continuation_max_bytes,
        }),
    };
    return wrapper;
}

pub const RestoreContinuationError = error{
    OutOfMemory,
    ContinuationDisabled,
    ContinuationUnavailable,
    InvalidContinuation,
};

/// Replay a decoded continuation exactly once into a newly created C terminal
/// and verify that the persistent stream exports the identical canonical
/// bytes. The terminal remains valid on error and may be freed normally.
pub fn restoreContinuation(
    terminal_: Terminal,
    continuation: []const u8,
) RestoreContinuationError!void {
    const wrapper = terminal_ orelse return error.InvalidContinuation;
    if (continuation.len > 0) wrapper.stream.nextSlice(continuation);

    var exported: std.Io.Writer.Allocating = .init(wrapper.terminal.gpa());
    defer exported.deinit();
    wrapper.stream.writeContinuation(&exported.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        error.ContinuationDisabled => return error.ContinuationDisabled,
        error.ContinuationUnavailable => return error.ContinuationUnavailable,
    };
    if (!std.mem.eql(u8, continuation, exported.written())) {
        return error.InvalidContinuation;
    }
}

pub const FromDecodedError = error{
    OutOfMemory,
    InvalidContinuation,
};

/// Transfer a core snapshot result into a caller-owned C terminal.
///
/// This function consumes `io` on every path. The decoded terminal is
/// transferred only after its final heap address has been allocated; its
/// continuation remains in `decoded` and is replayed before returning.
/// Replay uses a temporary exact-size tracker which is disabled before the
/// terminal crosses the C ABI, restoring the ordinary C default policy.
pub fn fromDecoded(
    alloc: std.mem.Allocator,
    io: Io,
    decoded: *snapshot_core.Decoded,
) FromDecodedError!Terminal {
    const native = alloc.create(ZigTerminal) catch {
        io.deinit(alloc);
        return error.OutOfMemory;
    };
    native.* = decoded.toOwned();

    const continuation = switch (decoded.continuation) {
        .ground => "",
        .bytes => |bytes| bytes,
    };

    // Non-ground state needs tracking only long enough to verify that replay
    // reconstructed the exact canonical continuation. Ground state needs no
    // tracker at all.
    const terminal = wrap(alloc, native, io, continuation.len) catch |err| {
        native.deinit(alloc);
        alloc.destroy(native);
        io.deinit(alloc);
        return err;
    };
    errdefer free(terminal);

    if (continuation.len > 0) {
        restoreContinuation(terminal, continuation) catch |err| return switch (err) {
            // The decoded bytes exactly fit this fresh tracker's cap, so
            // losing them while replaying can only be an allocation failure.
            error.OutOfMemory,
            error.ContinuationUnavailable,
            => error.OutOfMemory,
            error.ContinuationDisabled,
            error.InvalidContinuation,
            => error.InvalidContinuation,
        };
    }

    // Decoder validation limits are not terminal runtime policy. A restored
    // terminal always starts with the same disabled tracking default as new.
    setContinuationMaxBytes(terminal.?, default_continuation_max_bytes);
    return terminal;
}

const NewError = error{
    InvalidValue,
    OutOfMemory,
};

pub fn new(
    alloc_: ?*const CAllocator,
    result: *Terminal,
    cols: size.CellCountInt,
    rows: size.CellCountInt,
) callconv(lib.calling_conv) Result {
    result.* = new_(alloc_, cols, rows) catch |err| {
        result.* = null;
        return switch (err) {
            error.InvalidValue => .invalid_value,
            error.OutOfMemory => .out_of_memory,
        };
    };

    return .success;
}

fn new_(
    alloc_: ?*const CAllocator,
    cols: size.CellCountInt,
    rows: size.CellCountInt,
) NewError!Terminal {
    if (cols == 0 or rows == 0) return error.InvalidValue;

    const alloc = lib.alloc.default(alloc_);
    const t = alloc.create(ZigTerminal) catch
        return error.OutOfMemory;
    errdefer alloc.destroy(t);

    const io = try Io.init(alloc);
    errdefer io.deinit(alloc);

    // Setup our terminal
    t.* = try .init(
        io.io(),
        alloc,
        .{
            .cols = cols,
            .rows = rows,
        },
    );
    errdefer t.deinit(alloc);

    // libghostty-vt embedders don't necessarily install Ghostty's shell
    // integration, so don't assume OSC 133 prompts can be redrawn on resize.
    // Shells can still opt in with OSC 133;A;redraw=1.
    t.flags.shell_redraws_prompt = .false;

    return try wrap(
        alloc,
        t,
        io,
        default_continuation_max_bytes,
    );
}

pub fn vt_write(
    terminal_: Terminal,
    ptr: [*]const u8,
    len: usize,
) callconv(lib.calling_conv) void {
    const wrapper = terminal_ orelse return;
    wrapper.stream.nextSlice(ptr[0..len]);
}

pub const ContinuationWriteError = error{
    InvalidValue,
    WriteFailed,
    ContinuationDisabled,
    ContinuationUnavailable,
};

/// Write the exact replay-safe continuation for a C terminal to a Zig writer.
/// Snapshot encoding uses this helper so it can preflight continuation state
/// without converting its allocator or writer through the C ABI.
pub fn continuationWriteIo(
    terminal_: Terminal,
    writer: *std.Io.Writer,
) ContinuationWriteError!void {
    // Keep handle validation here so the three public output forms and the
    // snapshot encoder all use exactly the same continuation preflight.
    const wrapper = terminal_ orelse return error.InvalidValue;

    // Stream owns the tracker and distinguishes disabled tracking from a
    // tracker that lost bytes after allocation failure or limit overflow.
    try wrapper.stream.writeContinuation(writer);
}

pub const ContinuationAllocError = error{
    InvalidValue,
    OutOfMemory,
    ContinuationDisabled,
    ContinuationUnavailable,
};

/// Return an allocator-owned copy of the terminal's replay-safe continuation.
/// The caller owns the returned slice and must free it with `alloc`.
///
/// If `allow_untracked_ground` is true, disabled tracking is accepted only
/// when the stream is provably at ground and an owned empty slice is returned.
pub fn continuationAllocIo(
    terminal_: Terminal,
    alloc: std.mem.Allocator,
    allow_untracked_ground: bool,
) ContinuationAllocError![]u8 {
    const wrapper = terminal_ orelse return error.InvalidValue;
    if (allow_untracked_ground and
        wrapper.stream.continuation == null and
        wrapper.stream.ground())
    {
        return alloc.dupe(u8, "") catch error.OutOfMemory;
    }

    // The allocating writer gives snapshot encoding and the public allocation
    // API one common way to obtain an exact owned continuation.
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    // A write failure from an Allocating writer can only be allocation failure;
    // no external callback participates in this path.
    continuationWriteIo(terminal_, &aw.writer) catch |err| switch (err) {
        error.InvalidValue => return error.InvalidValue,
        error.WriteFailed => return error.OutOfMemory,
        error.ContinuationDisabled => return error.ContinuationDisabled,
        error.ContinuationUnavailable => return error.ContinuationUnavailable,
    };

    // Transfer the buffer out before the deferred writer cleanup runs.
    return aw.toOwnedSlice() catch error.OutOfMemory;
}

/// Map errors that are intrinsic to continuation export. Public callback
/// failures receive finer classification in `continuation_write` below.
fn continuationErrorResult(err: ContinuationWriteError) Result {
    return switch (err) {
        error.InvalidValue => .invalid_value,
        error.WriteFailed => .io_error,
        error.ContinuationDisabled => .invalid_value,
        error.ContinuationUnavailable => .invalid_value,
    };
}

pub fn continuation_write(
    terminal_: Terminal,
    writer: c_io.Writer,
) callconv(lib.calling_conv) Result {
    // Reject the missing callback before invoking the common helper so this is
    // classified as a bad argument rather than a write failure.
    if (writer.write == null) return .invalid_value;

    // The callback was validated above, so invalid_write can only mean output
    // accounting overflow. Keep that distinct from callback rejection.
    var adapter: c_io.WriterAdapter = .init(writer);
    continuationWriteIo(terminal_, &adapter.interface) catch |err| {
        if (err == error.WriteFailed) {
            if (adapter.invalid_write) return .limit_exceeded;
            if (adapter.callback_failed) return .io_error;
        }
        return continuationErrorResult(err);
    };
    return .success;
}

pub fn continuation_buf(
    terminal_: Terminal,
    out_: ?[*]u8,
    out_len: usize,
    out_written_: ?*usize,
) callconv(lib.calling_conv) Result {
    const out_written = out_written_ orelse return .invalid_value;
    // All failure paths leave deterministic output metadata.
    out_written.* = 0;
    if (out_ == null and out_len != 0) return .invalid_value;

    if (out_ == null) {
        // A null/zero destination is the explicit size-query form. Discarding
        // runs the real exporter, so disabled or unavailable tracking is still
        // detected before a required length is reported.
        var discarding: std.Io.Writer.Discarding = .init(&.{});
        continuationWriteIo(terminal_, &discarding.writer) catch |err|
            return continuationErrorResult(err);
        out_written.* = @intCast(discarding.count);
        return .out_of_space;
    }

    // Fixed writers report WriteFailed when capacity is exhausted. The stream
    // exporter itself remains all-or-nothing from the API's perspective.
    var writer: std.Io.Writer = .fixed(out_.?[0..out_len]);
    continuationWriteIo(terminal_, &writer) catch |err| switch (err) {
        error.WriteFailed => {
            // Re-run against a counter to return the full required capacity,
            // not merely the prefix that fit in the caller's buffer.
            var discarding: std.Io.Writer.Discarding = .init(&.{});
            continuationWriteIo(terminal_, &discarding.writer) catch |count_err|
                return continuationErrorResult(count_err);
            out_written.* = @intCast(discarding.count);
            return .out_of_space;
        },
        else => return continuationErrorResult(err),
    };

    // `end` is the initialized prefix of the fixed destination.
    out_written.* = writer.end;
    return .success;
}

pub fn continuation_alloc(
    terminal_: Terminal,
    alloc_: ?*const CAllocator,
    out_ptr_: ?*?[*]u8,
    out_len_: ?*usize,
) callconv(lib.calling_conv) Result {
    const out_ptr = out_ptr_ orelse return .invalid_value;
    const out_len = out_len_ orelse return .invalid_value;
    // Make ownership unambiguous even if validation or allocation fails.
    out_ptr.* = null;
    out_len.* = 0;

    // Resolve NULL to libghostty-vt's default allocator before entering the
    // shared Zig allocation path.
    const bytes = continuationAllocIo(
        terminal_,
        lib.alloc.default(alloc_),
        false,
    ) catch |err| return switch (err) {
        error.InvalidValue => .invalid_value,
        error.OutOfMemory => .out_of_memory,
        error.ContinuationDisabled => .invalid_value,
        error.ContinuationUnavailable => .invalid_value,
    };

    // Ownership crosses the ABI here; callers release this exact pointer and
    // length with ghostty_free and the same allocator selection.
    out_ptr.* = bytes.ptr;
    out_len.* = bytes.len;
    return .success;
}

fn continuationMaxBytes(wrapper: *const TerminalWrapper) usize {
    // Absence of a tracker is the public representation of disabled tracking.
    return if (wrapper.stream.continuation) |tracker|
        tracker.max_bytes
    else
        0;
}

/// Change continuation tracking policy without disturbing normal VT parser
/// state. Bytes which were not retained while disabled or after exceeding an
/// earlier cap cannot be reconstructed: export remains unavailable until a
/// later feed reaches ground or contains a new replay start.
fn setContinuationMaxBytes(wrapper: *TerminalWrapper, max_bytes: usize) void {
    if (max_bytes == 0) {
        // Disabling releases retained bytes immediately. Parser and UTF-8 state
        // continue normally; only future replay/export information is lost.
        if (wrapper.stream.continuation) |*tracker| tracker.deinit();
        wrapper.stream.continuation = null;
        return;
    }

    if (wrapper.stream.continuation) |*tracker| {
        // Changing a live cap preserves retained bytes when they still fit.
        tracker.max_bytes = max_bytes;
        if (tracker.bytes.items.len > max_bytes) {
            // Once a retained prefix is discarded it cannot be reconstructed
            // from parser state alone. Mark it broken until Stream observes a
            // ground state or a new replay-safe sequence start.
            tracker.bytes.clearRetainingCapacity();
            tracker.broken = true;
        }
        return;
    }

    // Enabling from zero starts an empty tracker owned by the terminal's
    // allocator. It can immediately track only if no earlier bytes are needed.
    wrapper.stream.continuation = .init(wrapper.terminal.gpa(), max_bytes);
    if (!wrapper.stream.ground()) {
        // The parser was already mid-sequence while tracking was disabled, so
        // exporting now would omit an unknown prefix.
        wrapper.stream.continuation.?.broken = true;
    }
}

pub fn compression_activity(
    terminal_: Terminal,
    out_activity_: ?*u64,
) callconv(lib.calling_conv) Result {
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    const out_activity = out_activity_ orelse return .invalid_value;
    out_activity.* = t.compressionActivity();
    return .success;
}

pub fn compress(
    terminal_: Terminal,
    mode_: c_int,
    out_result_: ?*CompressionResult,
) callconv(lib.calling_conv) Result {
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    const out_result = out_result_ orelse return .invalid_value;
    const mode = std.enums.fromInt(CompressionMode, mode_) orelse return .invalid_value;
    out_result.* = t.compress(mode);
    return .success;
}

/// C: GhosttyTerminalOption
pub const Option = enum(c_int) {
    userdata = 0,
    write_pty = 1,
    bell = 2,
    enquiry = 3,
    xtversion = 4,
    title_changed = 5,
    size_cb = 6,
    color_scheme = 7,
    device_attributes = 8,
    title = 9,
    pwd = 10,
    color_foreground = 11,
    color_background = 12,
    color_cursor = 13,
    color_palette = 14,
    kitty_image_storage_limit = 15,
    kitty_image_medium_file = 16,
    kitty_image_medium_temp_file = 17,
    kitty_image_medium_shared_mem = 18,
    apc_max_bytes = 19,
    apc_max_bytes_kitty = 20,
    selection = 21,
    default_cursor_style = 22,
    default_cursor_blink = 23,
    glyph_protocol = 24,
    pwd_changed = 25,
    clipboard_write = 26,
    scrollback_max_bytes = 27,
    scrollback_max_lines = 28,
    desktop_notification = 29,
    progress_report = 30,
    continuation_max_bytes = 31,
    title_report = 32,
    mode_default = 33,
    mode = 34,

    /// Input type expected for setting the option.
    pub fn InType(comptime self: Option) type {
        return switch (self) {
            .userdata => ?*const anyopaque,
            .write_pty => ?Effects.WritePtyFn,
            .bell => ?Effects.BellFn,
            .color_scheme => ?Effects.ColorSchemeFn,
            .desktop_notification => ?Effects.DesktopNotificationFn,
            .device_attributes => ?Effects.DeviceAttributesFn,
            .enquiry => ?Effects.EnquiryFn,
            .xtversion => ?Effects.XtversionFn,
            .title_changed => ?Effects.TitleChangedFn,
            .pwd_changed => ?Effects.PwdChangedFn,
            .progress_report => ?Effects.ProgressReportFn,
            .size_cb => ?Effects.SizeFn,
            .clipboard_write => ?Effects.ClipboardWriteFn,
            .title, .pwd => ?*const lib.String,
            .color_foreground, .color_background, .color_cursor => ?*const color.RGB.C,
            .color_palette => ?*const color.PaletteC,
            .kitty_image_storage_limit => ?*const u64,
            .kitty_image_medium_file,
            .kitty_image_medium_shared_mem,
            .glyph_protocol,
            .title_report,
            => ?*const bool,
            .kitty_image_medium_temp_file => ?*const lib.String,
            .apc_max_bytes,
            .apc_max_bytes_kitty,
            .scrollback_max_bytes,
            .scrollback_max_lines,
            .continuation_max_bytes,
            => ?*const usize,
            .selection => ?*const selection_c.CSelection,
            .default_cursor_style => ?*const TerminalCursorStyle,
            .default_cursor_blink => ?*const bool,
            .mode, .mode_default => ?*const ModeConfig,
        };
    }
};

pub fn set(
    terminal_: Terminal,
    option: Option,
    value: ?*const anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.enums.fromInt(Option, @intFromEnum(option)) orelse {
            log.warn("terminal_set invalid option value={d}", .{@intFromEnum(option)});
            return .invalid_value;
        };
    }

    const wrapper = terminal_ orelse return .invalid_value;

    return switch (option) {
        inline else => |comptime_option| setTyped(
            wrapper,
            comptime_option,
            @ptrCast(@alignCast(value)),
        ),
    };
}

fn setTyped(
    wrapper: *TerminalWrapper,
    comptime option: Option,
    value: option.InType(),
) Result {
    switch (option) {
        .userdata => wrapper.effects.userdata = @constCast(value),
        .write_pty => wrapper.effects.write_pty = value,
        .bell => wrapper.effects.bell = value,
        .color_scheme => wrapper.effects.color_scheme = value,
        .desktop_notification => wrapper.effects.desktop_notification = value,
        .device_attributes => wrapper.effects.device_attributes_cb = value,
        .enquiry => wrapper.effects.enquiry = value,
        .xtversion => wrapper.effects.xtversion = value,
        .title_changed => wrapper.effects.title_changed = value,
        .pwd_changed => wrapper.effects.pwd_changed = value,
        .progress_report => wrapper.effects.progress_report = value,
        .size_cb => wrapper.effects.size_cb = value,
        .clipboard_write => wrapper.effects.clipboard_write = value,
        .title_report => wrapper.stream.handler.title_report = if (value) |ptr|
            ptr.*
        else
            false,
        .title => {
            const str = if (value) |v| v.ptr[0..v.len] else "";
            wrapper.terminal.setTitle(str) catch return .out_of_memory;
        },
        .pwd => {
            const str = if (value) |v| v.ptr[0..v.len] else "";
            wrapper.terminal.setPwd(str) catch return .out_of_memory;
        },
        .color_foreground => {
            wrapper.terminal.colors.foreground.default = if (value) |v| .fromC(v.*) else null;
            wrapper.terminal.flags.dirty.palette = true;
        },
        .color_background => {
            wrapper.terminal.colors.background.default = if (value) |v| .fromC(v.*) else null;
            wrapper.terminal.flags.dirty.palette = true;
        },
        .color_cursor => {
            wrapper.terminal.colors.cursor.default = if (value) |v| .fromC(v.*) else null;
            wrapper.terminal.flags.dirty.palette = true;
        },
        .color_palette => {
            wrapper.terminal.colors.palette.changeDefault(
                if (value) |v| color.paletteZval(v) else color.default,
            );
            wrapper.terminal.flags.dirty.palette = true;
        },
        .kitty_image_storage_limit => {
            if (comptime !build_options.kitty_graphics) return .success;
            const limit: usize = if (value) |v| @intCast(v.*) else 0;
            var it = wrapper.terminal.screens.all.iterator();
            while (it.next()) |entry| {
                const screen = entry.value.*;
                screen.kitty_images.setLimit(screen.io, screen.alloc, screen, limit);
            }
        },
        .kitty_image_medium_file,
        .kitty_image_medium_shared_mem,
        => {
            if (comptime !build_options.kitty_graphics) return .success;
            const val = (value orelse return .success).*;
            var it = wrapper.terminal.screens.all.iterator();
            while (it.next()) |entry| {
                const screen = entry.value.*;
                switch (option) {
                    .kitty_image_medium_file => screen.kitty_images.image_limits.file = val,
                    .kitty_image_medium_shared_mem => screen.kitty_images.image_limits.shared_memory = val,
                    else => unreachable,
                }
            }
        },
        .kitty_image_medium_temp_file => {
            if (comptime !build_options.kitty_graphics) return .success;
            if (value) |v| {
                if (v.len > wrapper.tmp_dir_path.len) return .out_of_memory;
                @memcpy(wrapper.tmp_dir_path[0..v.len], v.ptr[0..v.len]);
                var it = wrapper.terminal.screens.all.iterator();
                while (it.next()) |entry| {
                    const screen = entry.value.*;
                    screen.kitty_images.image_limits.temporary_file = .{
                        .enabled = .{ .directory = wrapper.tmp_dir_path[0..v.len] },
                    };
                }
            } else {
                var it = wrapper.terminal.screens.all.iterator();
                while (it.next()) |entry| {
                    const screen = entry.value.*;
                    screen.kitty_images.image_limits.temporary_file = .disabled;
                }
            }
        },
        .apc_max_bytes => {
            wrapper.stream.handler.apc_handler.max_bytes = if (value) |ptr|
                .initFull(ptr.*)
            else
                .{};
        },
        .apc_max_bytes_kitty => {
            if (value) |ptr| {
                wrapper.stream.handler.apc_handler.max_bytes.put(.kitty, ptr.*);
            } else {
                wrapper.stream.handler.apc_handler.max_bytes.remove(.kitty);
            }
        },
        .glyph_protocol => {
            const enabled = (value orelse return .success).*;
            wrapper.stream.handler.apc_handler.enable(.glyph, enabled);
            if (!enabled) wrapper.terminal.glyph_glossary.clearAndFree(wrapper.terminal.gpa());
        },
        .selection => {
            if (value) |ptr| {
                const sel = ptr.toZig() orelse return .invalid_value;
                wrapper.terminal.screens.active.select(sel) catch return .out_of_memory;
            } else {
                wrapper.terminal.screens.active.clearSelection();
            }
        },
        .default_cursor_style => {
            const style = (if (value) |ptr| ptr.* else TerminalCursorStyle.block).toZig() orelse return .invalid_value;
            wrapper.terminal.setDefaultCursorStyle(style);
        },
        .default_cursor_blink => {
            const blink = if (value) |ptr| ptr.* else false;
            wrapper.terminal.setDefaultCursorBlink(blink);
        },
        .scrollback_max_bytes => wrapper.terminal.setScrollbackMaxBytes(
            if (value) |ptr| ptr.* else null,
        ),
        .scrollback_max_lines => wrapper.terminal.setScrollbackMaxLines(
            if (value) |ptr| ptr.* else null,
        ),
        .continuation_max_bytes => setContinuationMaxBytes(
            wrapper,
            if (value) |ptr| ptr.* else default_continuation_max_bytes,
        ),
        .mode, .mode_default => {
            const config = (value orelse return .invalid_value).*;
            const mode = config.toMode() orelse return .invalid_value;
            switch (option) {
                .mode => wrapper.terminal.modes.set(mode, config.value),
                .mode_default => {
                    if (!modes.defaultConfigurable(mode)) return .invalid_value;
                    wrapper.terminal.modes.setDefault(mode, config.value);
                },
                else => unreachable,
            }
        },
    }
    return .success;
}

/// C: GhosttyTerminalCursorStyle
pub const TerminalCursorStyle = enum(c_int) {
    bar = 0,
    block = 1,
    underline = 2,
    block_hollow = 3,
    _,

    fn toZig(self: TerminalCursorStyle) ?Screen.CursorStyle {
        return switch (self) {
            .bar => .bar,
            .block => .block,
            .underline => .underline,
            .block_hollow => .block_hollow,
            _ => null,
        };
    }
};

/// C: GhosttyDeviceAttributes
pub const DeviceAttributes = Effects.CDeviceAttributes;

/// C: GhosttyTerminalScrollViewport
pub const ScrollViewport = ZigTerminal.ScrollViewport.C;

pub fn scroll_viewport(
    terminal_: Terminal,
    behavior: ScrollViewport,
) callconv(lib.calling_conv) void {
    const t: *ZigTerminal = (terminal_ orelse return).terminal;
    t.scrollViewport(switch (behavior.tag) {
        .top => .top,
        .bottom => .bottom,
        .delta => .{ .delta = behavior.value.delta },
        .row => .{ .row = behavior.value.row },
    });
}

pub fn resize(
    terminal_: Terminal,
    cols: size.CellCountInt,
    rows: size.CellCountInt,
    cell_width_px: u32,
    cell_height_px: u32,
) callconv(lib.calling_conv) Result {
    const wrapper = terminal_ orelse return .invalid_value;
    wrapper.stream.handler.resize(.{
        .cols = cols,
        .rows = rows,
        .cell_size_px = .{
            .width = cell_width_px,
            .height = cell_height_px,
        },
    }) catch |err| return switch (err) {
        error.InvalidValue => .invalid_value,
        error.OutOfMemory => .out_of_memory,
    };

    return .success;
}

pub fn reset(terminal_: Terminal) callconv(lib.calling_conv) void {
    const t: *ZigTerminal = (terminal_ orelse return).terminal;
    t.fullReset();
}

/// C: GhosttyKittyGraphics
pub const KittyGraphics = kitty_gfx_c.KittyGraphics;

/// C: GhosttyTerminalScreen
pub const TerminalScreen = ScreenSet.Key;

/// C: GhosttyTerminalScrollbar
pub const TerminalScrollbar = PageList.Scrollbar.C;

/// C: GhosttyTerminalData
pub const TerminalData = enum(c_int) {
    invalid = 0,
    cols = 1,
    rows = 2,
    cursor_x = 3,
    cursor_y = 4,
    cursor_pending_wrap = 5,
    active_screen = 6,
    cursor_visible = 7,
    kitty_keyboard_flags = 8,
    scrollbar = 9,
    cursor_style = 10,
    mouse_tracking = 11,
    title = 12,
    pwd = 13,
    total_rows = 14,
    scrollback_rows = 15,
    width_px = 16,
    height_px = 17,
    color_foreground = 18,
    color_background = 19,
    color_cursor = 20,
    color_palette = 21,
    color_foreground_default = 22,
    color_background_default = 23,
    color_cursor_default = 24,
    color_palette_default = 25,
    kitty_image_storage_limit = 26,
    kitty_image_medium_file = 27,
    kitty_image_medium_temp_file = 28,
    kitty_image_medium_shared_mem = 29,
    kitty_graphics = 30,
    selection = 31,
    viewport_active = 32,
    vt_processing_error = 33,
    scrollback_max_bytes = 34,
    scrollback_max_lines = 35,
    continuation_max_bytes = 36,
    mode = 37,

    /// Output type expected for querying the data of the given kind.
    pub fn OutType(comptime self: TerminalData) type {
        return switch (self) {
            .invalid => void,
            .cols, .rows, .cursor_x, .cursor_y => size.CellCountInt,
            .cursor_pending_wrap,
            .cursor_visible,
            .mouse_tracking,
            .viewport_active,
            .vt_processing_error,
            => bool,
            .active_screen => TerminalScreen,
            .kitty_keyboard_flags => u8,
            .scrollbar => TerminalScrollbar,
            .cursor_style => style_c.Style,
            .title, .pwd => lib.String,
            .total_rows,
            .scrollback_rows,
            .scrollback_max_bytes,
            .scrollback_max_lines,
            .continuation_max_bytes,
            => usize,
            .width_px, .height_px => u32,
            .color_foreground,
            .color_background,
            .color_cursor,
            .color_foreground_default,
            .color_background_default,
            .color_cursor_default,
            => color.RGB.C,
            .color_palette, .color_palette_default => color.PaletteC,
            .kitty_image_storage_limit => u64,
            .kitty_image_medium_file,
            .kitty_image_medium_shared_mem,
            => bool,
            .kitty_image_medium_temp_file => lib.String,
            .kitty_graphics => KittyGraphics,
            .selection => selection_c.CSelection,
            .mode => ModeConfig,
        };
    }
};

pub fn get(
    terminal_: Terminal,
    data: TerminalData,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.enums.fromInt(TerminalData, @intFromEnum(data)) orelse {
            log.warn("terminal_get invalid data value={d}", .{@intFromEnum(data)});
            return .invalid_value;
        };
    }

    const out_ptr = out orelse return .invalid_value;

    return switch (data) {
        .invalid => .invalid_value,
        inline else => |comptime_data| getTyped(
            terminal_,
            comptime_data,
            @ptrCast(@alignCast(out_ptr)),
        ),
    };
}

pub fn get_multi(
    terminal_: Terminal,
    count: usize,
    keys: ?[*]const TerminalData,
    values: ?[*]?*anyopaque,
    out_written: ?*usize,
) callconv(lib.calling_conv) Result {
    const k = keys orelse return .invalid_value;
    const v = values orelse return .invalid_value;

    for (0..count) |i| {
        const result = get(terminal_, k[i], v[i]);
        if (result != .success) {
            if (out_written) |w| w.* = i;
            return result;
        }
    }
    if (out_written) |w| w.* = count;
    return .success;
}

fn getTyped(
    terminal_: Terminal,
    comptime data: TerminalData,
    out: *data.OutType(),
) Result {
    const wrapper = terminal_ orelse return .invalid_value;
    const t: *ZigTerminal = wrapper.terminal;
    switch (data) {
        .invalid => return .invalid_value,
        .cols => out.* = t.cols,
        .rows => out.* = t.rows,
        .cursor_x => out.* = t.screens.active.cursor.x,
        .cursor_y => out.* = t.screens.active.cursor.y,
        .cursor_pending_wrap => out.* = t.screens.active.cursor.pending_wrap,
        .active_screen => out.* = t.screens.active_key,
        .cursor_visible => out.* = t.modes.get(.cursor_visible),
        .kitty_keyboard_flags => out.* = @as(u8, t.screens.active.kitty_keyboard.current().int()),
        .scrollbar => out.* = t.screens.active.pages.scrollbar().cval(),
        .cursor_style => out.* = .fromStyle(t.screens.active.cursor.style),
        .mouse_tracking => out.* = t.modes.get(.mouse_event_x10) or
            t.modes.get(.mouse_event_normal) or
            t.modes.get(.mouse_event_button) or
            t.modes.get(.mouse_event_any),
        .title => {
            const title = t.getTitle() orelse "";
            out.* = .{ .ptr = title.ptr, .len = title.len };
        },
        .pwd => {
            const pwd = t.getPwd() orelse "";
            out.* = .{ .ptr = pwd.ptr, .len = pwd.len };
        },
        .total_rows => out.* = t.screens.active.pages.total_rows,
        .scrollback_rows => out.* = t.screens.active.pages.total_rows - t.rows,
        .width_px => out.* = t.width_px,
        .height_px => out.* = t.height_px,
        .color_foreground => out.* = (t.colors.foreground.get() orelse return .no_value).cval(),
        .color_background => out.* = (t.colors.background.get() orelse return .no_value).cval(),
        .color_cursor => out.* = (t.colors.cursor.get() orelse return .no_value).cval(),
        .color_foreground_default => out.* = (t.colors.foreground.default orelse return .no_value).cval(),
        .color_background_default => out.* = (t.colors.background.default orelse return .no_value).cval(),
        .color_cursor_default => out.* = (t.colors.cursor.default orelse return .no_value).cval(),
        .color_palette => out.* = color.paletteCval(&t.colors.palette.current),
        .color_palette_default => out.* = color.paletteCval(&t.colors.palette.original),
        .kitty_image_storage_limit => {
            if (comptime !build_options.kitty_graphics) return .no_value;
            out.* = @intCast(t.screens.active.kitty_images.total_limit);
        },
        .kitty_image_medium_file => {
            if (comptime !build_options.kitty_graphics) return .no_value;
            out.* = t.screens.active.kitty_images.image_limits.file;
        },
        .kitty_image_medium_temp_file => {
            if (comptime !build_options.kitty_graphics) return .no_value;
            const dir = switch (t.screens.active.kitty_images.image_limits.temporary_file) {
                .enabled => |d| d.directory,
                .disabled => "",
            };
            out.* = .{ .ptr = dir.ptr, .len = dir.len };
        },
        .kitty_image_medium_shared_mem => {
            if (comptime !build_options.kitty_graphics) return .no_value;
            out.* = t.screens.active.kitty_images.image_limits.shared_memory;
        },
        .kitty_graphics => {
            if (comptime !build_options.kitty_graphics) return .no_value;
            out.* = &t.screens.active.kitty_images;
        },
        .selection => out.* = selection_c.CSelection.fromZig(
            t.screens.active.selection orelse return .no_value,
        ),
        .viewport_active => out.* = t.screens.active.pages.viewport == .active,
        .vt_processing_error => out.* = wrapper.stream.handler.semantic_failure,
        .scrollback_max_bytes => {
            const max = t.screens.get(.primary).?.pages.limits.bytes.explicit;
            if (max == std.math.maxInt(usize)) return .no_value;
            out.* = max;
        },
        .scrollback_max_lines => {
            const max = t.screens.get(.primary).?.pages.limits.lines.explicit;
            if (max == std.math.maxInt(usize)) return .no_value;
            out.* = max;
        },
        .continuation_max_bytes => out.* = continuationMaxBytes(wrapper),
        .mode => {
            const mode = out.toMode() orelse return .invalid_value;
            out.value = t.modes.get(mode);
        },
    }

    return .success;
}

pub fn grid_ref(
    terminal_: Terminal,
    pt: point.Point.C,
    out_ref: ?*grid_ref_c.CGridRef,
) callconv(lib.calling_conv) Result {
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    const zig_pt: point.Point = .fromC(pt);
    const p = t.screens.active.pages.pin(zig_pt) orelse
        return .invalid_value;
    if (out_ref) |out| out.* = grid_ref_c.CGridRef.fromPin(p);
    return .success;
}

pub fn grid_ref_track(
    terminal_: Terminal,
    pt: point.Point.C,
    out_ref: ?*grid_ref_tracked_c.CTrackedGridRef,
) callconv(lib.calling_conv) Result {
    const wrapper = terminal_ orelse return .invalid_value;
    const out = out_ref orelse return .invalid_value;
    out.* = null;

    const t: *ZigTerminal = wrapper.terminal;
    const list = &t.screens.active.pages;
    const p = list.pin(.fromC(pt)) orelse return .invalid_value;
    const tracked_pin = list.trackPin(p) catch return .out_of_memory;

    const alloc = t.gpa();
    const ref = alloc.create(grid_ref_tracked_c.TrackedGridRef) catch {
        list.untrackPin(tracked_pin);
        return .out_of_memory;
    };
    ref.* = .{
        .alloc = alloc,
        .terminal = wrapper,
        .screen_key = t.screens.active_key,
        .screen_generation = t.screens.generation(t.screens.active_key),
        .pin = tracked_pin,
    };

    // Store the tracked ref in the terminal so that when we free
    // the terminal the tracked ref can be detached safely.
    wrapper.tracked_grid_refs.putNoClobber(
        alloc,
        ref,
        {},
    ) catch {
        list.untrackPin(tracked_pin);
        alloc.destroy(ref);
        return .out_of_memory;
    };

    out.* = ref;
    return .success;
}

pub fn point_from_grid_ref(
    terminal_: Terminal,
    ref: *const grid_ref_c.CGridRef,
    tag: point.Tag,
    out: ?*point.Coordinate,
) callconv(lib.calling_conv) Result {
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    const p = ref.toPin() orelse return .invalid_value;
    const pt = t.screens.active.pages.pointFromPin(tag, p) orelse
        return .no_value;
    if (out) |o| o.* = pt.coord();
    return .success;
}

pub fn free(terminal_: Terminal) callconv(lib.calling_conv) void {
    const wrapper = terminal_ orelse return;
    const t = wrapper.terminal;
    const alloc = t.gpa();

    for (wrapper.tracked_grid_refs.keys()) |ref| ref.terminal = null;
    wrapper.tracked_grid_refs.deinit(alloc);
    wrapper.stream.deinit();
    t.deinit(alloc);
    wrapper.io.deinit(alloc);
    alloc.destroy(t);
    alloc.destroy(wrapper);
}

fn testEnableContinuation(terminal: Terminal) !void {
    const limit: usize = 1024;
    try testing.expectEqual(
        Result.success,
        set(terminal, .continuation_max_bytes, &limit),
    );
}

test "new/free" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));

    try testing.expect(t != null);
    free(t);
}

test "new invalid value" {
    var t: Terminal = null;

    try testing.expectEqual(Result.invalid_value, new(
        &lib.alloc.test_allocator,
        &t,
        0,
        24,
    ));
    try testing.expect(t == null);

    try testing.expectEqual(Result.invalid_value, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        0,
    ));
    try testing.expect(t == null);
}

test "continuation option and data" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    var value: usize = 0;
    try testing.expectEqual(
        Result.success,
        get(t, .continuation_max_bytes, @ptrCast(&value)),
    );
    try testing.expectEqual(default_continuation_max_bytes, value);

    const custom: usize = 1234;
    try testing.expectEqual(
        Result.success,
        set(t, .continuation_max_bytes, &custom),
    );
    try testing.expectEqual(
        Result.success,
        get(t, .continuation_max_bytes, @ptrCast(&value)),
    );
    try testing.expectEqual(custom, value);

    try testing.expectEqual(
        Result.success,
        set(t, .continuation_max_bytes, null),
    );
    try testing.expectEqual(
        Result.success,
        get(t, .continuation_max_bytes, @ptrCast(&value)),
    );
    try testing.expectEqual(default_continuation_max_bytes, value);

    const disabled: usize = 0;
    try testing.expectEqual(
        Result.success,
        set(t, .continuation_max_bytes, &disabled),
    );
    try testing.expectEqual(
        Result.success,
        get(t, .continuation_max_bytes, @ptrCast(&value)),
    );
    try testing.expectEqual(@as(usize, 0), value);

    var written: usize = 99;
    try testing.expectEqual(
        Result.invalid_value,
        continuation_buf(t, null, 0, &written),
    );
    try testing.expectEqual(@as(usize, 0), written);
}

test "continuation buffer and allocator export exact suffix" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    try testEnableContinuation(t);

    vt_write(t, "A\x1b[31", 5);

    var required: usize = 0;
    try testing.expectEqual(
        Result.out_of_space,
        continuation_buf(t, null, 0, &required),
    );
    try testing.expectEqual(@as(usize, 4), required);

    var short: [2]u8 = undefined;
    try testing.expectEqual(
        Result.out_of_space,
        continuation_buf(t, &short, short.len, &required),
    );
    try testing.expectEqual(@as(usize, 4), required);

    var buf: [8]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(
        Result.success,
        continuation_buf(t, &buf, buf.len, &written),
    );
    try testing.expectEqualStrings("\x1b[31", buf[0..written]);

    var out_ptr: ?[*]u8 = null;
    var out_len: usize = 0;
    try testing.expectEqual(Result.success, continuation_alloc(
        t,
        &lib.alloc.test_allocator,
        &out_ptr,
        &out_len,
    ));
    const allocated = out_ptr orelse return error.TestExpectedEqual;
    defer lib.alloc.default(&lib.alloc.test_allocator).free(allocated[0..out_len]);
    try testing.expectEqualStrings("\x1b[31", allocated[0..out_len]);

    vt_write(t, "m", 1);
    try testing.expectEqual(
        Result.out_of_space,
        continuation_buf(t, null, 0, &required),
    );
    try testing.expectEqual(@as(usize, 0), required);
}

test "continuation export tracks split UTF-8" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    try testEnableContinuation(t);

    const prefix = [_]u8{ 0xF0, 0x9F };
    vt_write(t, &prefix, prefix.len);

    var buf: [4]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(
        Result.success,
        continuation_buf(t, &buf, buf.len, &written),
    );
    try testing.expectEqualSlices(u8, &prefix, buf[0..written]);

    const suffix = [_]u8{ 0x98, 0x80 };
    vt_write(t, &suffix, suffix.len);
    try testing.expectEqual(
        Result.out_of_space,
        continuation_buf(t, null, 0, &written),
    );
    try testing.expectEqual(@as(usize, 0), written);
}

test "continuation callback writer reports success and failure" {
    const Sink = struct {
        bytes: [8]u8 = undefined,
        len: usize = 0,

        fn write(
            userdata: ?*anyopaque,
            data: [*]const u8,
            len: usize,
        ) callconv(lib.calling_conv) bool {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            if (len > self.bytes.len - self.len) return false;
            @memcpy(self.bytes[self.len..][0..len], data[0..len]);
            self.len += len;
            return true;
        }

        fn fail(
            _: ?*anyopaque,
            _: [*]const u8,
            _: usize,
        ) callconv(lib.calling_conv) bool {
            return false;
        }
    };

    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    try testEnableContinuation(t);
    vt_write(t, "\x1b[31", 4);

    var sink: Sink = .{};
    try testing.expectEqual(Result.success, continuation_write(t, .{
        .write = &Sink.write,
        .userdata = &sink,
    }));
    try testing.expectEqualStrings("\x1b[31", sink.bytes[0..sink.len]);

    try testing.expectEqual(Result.io_error, continuation_write(t, .{
        .write = &Sink.fail,
    }));
    try testing.expectEqual(
        Result.invalid_value,
        continuation_write(t, .{}),
    );
    try testing.expectEqual(Result.invalid_value, continuation_write(null, .{
        .write = &Sink.fail,
    }));
}

test "continuation runtime reconfiguration recovers safely" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const enough: usize = 8;
    try testing.expectEqual(
        Result.success,
        set(t, .continuation_max_bytes, &enough),
    );
    vt_write(t, "\x1b[123", 5);
    const too_small: usize = 2;
    try testing.expectEqual(
        Result.success,
        set(t, .continuation_max_bytes, &too_small),
    );

    var written: usize = 99;
    try testing.expectEqual(
        Result.invalid_value,
        continuation_buf(t, null, 0, &written),
    );
    try testing.expectEqual(@as(usize, 0), written);

    // Raising the limit cannot reconstruct discarded bytes, but a new ESC is
    // a complete replay start and repairs tracking without first grounding.
    try testing.expectEqual(
        Result.success,
        set(t, .continuation_max_bytes, &enough),
    );
    vt_write(t, "\x1b[", 2);
    var buf: [8]u8 = undefined;
    try testing.expectEqual(
        Result.success,
        continuation_buf(t, &buf, buf.len, &written),
    );
    try testing.expectEqualStrings("\x1b[", buf[0..written]);

    const disabled: usize = 0;
    try testing.expectEqual(
        Result.success,
        set(t, .continuation_max_bytes, &disabled),
    );
    try testing.expectEqual(
        Result.success,
        set(t, .continuation_max_bytes, &enough),
    );
    try testing.expectEqual(
        Result.invalid_value,
        continuation_buf(t, null, 0, &written),
    );

    // Completing the sequence reaches ground and resets the broken marker.
    vt_write(t, "m", 1);
    try testing.expectEqual(
        Result.out_of_space,
        continuation_buf(t, null, 0, &written),
    );
    try testing.expectEqual(@as(usize, 0), written);
}

test "continuation internal allocation and restoration" {
    var source: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &source,
        80,
        24,
    ));
    defer free(source);
    try testEnableContinuation(source);
    vt_write(source, "\x1b[31", 4);

    const alloc = lib.alloc.default(&lib.alloc.test_allocator);
    const bytes = try continuationAllocIo(source, alloc, false);
    defer alloc.free(bytes);
    try testing.expectEqualStrings("\x1b[31", bytes);

    var restored: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &restored,
        80,
        24,
    ));
    defer free(restored);
    try testEnableContinuation(restored);
    try restoreContinuation(restored, bytes);

    const reexported = try continuationAllocIo(restored, alloc, false);
    defer alloc.free(reexported);
    try testing.expectEqualStrings(bytes, reexported);

    var invalid: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &invalid,
        80,
        24,
    ));
    defer free(invalid);
    try testEnableContinuation(invalid);
    try testing.expectError(
        error.InvalidContinuation,
        restoreContinuation(invalid, "A"),
    );
}

test "set scrollback limits" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        3,
    ));
    defer free(t);

    const primary = t.?.terminal.screens.get(.primary).?;

    const max_bytes: usize = 0;
    try testing.expectEqual(
        Result.success,
        set(t, .scrollback_max_bytes, &max_bytes),
    );
    try testing.expectEqual(
        @as(usize, 0),
        primary.pages.limits.bytes.explicit,
    );
    try testing.expect(primary.no_scrollback);

    try testing.expectEqual(
        Result.success,
        set(t, .scrollback_max_bytes, null),
    );
    try testing.expectEqual(
        std.math.maxInt(usize),
        primary.pages.limits.bytes.explicit,
    );
    try testing.expect(!primary.no_scrollback);

    const max_lines: usize = 12;
    try testing.expectEqual(
        Result.success,
        set(t, .scrollback_max_lines, &max_lines),
    );
    try testing.expectEqual(
        max_lines,
        primary.pages.limits.lines.explicit,
    );

    try testing.expectEqual(
        Result.success,
        set(t, .scrollback_max_lines, null),
    );
    try testing.expectEqual(
        std.math.maxInt(usize),
        primary.pages.limits.lines.explicit,
    );
}

test "free null" {
    free(null);
}

test "scroll_viewport" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        5,
        2,
    ));
    defer free(t);

    const zt = t.?.terminal;

    var viewport_active: bool = false;
    try testing.expectEqual(Result.success, get(t, .viewport_active, @ptrCast(&viewport_active)));
    try testing.expect(viewport_active);

    // Write "hello" on the first line
    vt_write(t, "hello", 5);

    // Push "hello" into scrollback with 3 newlines (index = ESC D)
    vt_write(t, "\x1bD\x1bD\x1bD", 6);
    {
        // Viewport should be empty now since hello scrolled off
        const str = try zt.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }

    // Scroll to top: "hello" should be visible again
    scroll_viewport(t, .{ .tag = .top, .value = undefined });
    try testing.expectEqual(Result.success, get(t, .viewport_active, @ptrCast(&viewport_active)));
    try testing.expect(!viewport_active);
    {
        const str = try zt.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello", str);
    }

    // Scroll to bottom: viewport should be empty again
    scroll_viewport(t, .{ .tag = .bottom, .value = undefined });
    try testing.expectEqual(Result.success, get(t, .viewport_active, @ptrCast(&viewport_active)));
    try testing.expect(viewport_active);
    {
        const str = try zt.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }

    // Scroll up by delta to bring "hello" back into view
    scroll_viewport(t, .{ .tag = .delta, .value = .{ .delta = -3 } });
    try testing.expectEqual(Result.success, get(t, .viewport_active, @ptrCast(&viewport_active)));
    try testing.expect(!viewport_active);
    {
        const str = try zt.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello", str);
    }
}

test "scroll_viewport row" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        5,
        2,
    ));
    defer free(t);

    const zt = t.?.terminal;

    // Write 4 rows so that rows "1" and "2" are pushed into scrollback:
    // total rows is 4, viewport length is 2.
    vt_write(t, "1\r\n2\r\n3\r\n4", 10);

    var viewport_active: bool = false;
    try testing.expectEqual(Result.success, get(t, .viewport_active, @ptrCast(&viewport_active)));
    try testing.expect(viewport_active);

    // Row 0 is the top of the scrollback.
    scroll_viewport(t, .{ .tag = .row, .value = .{ .row = 0 } });
    try testing.expectEqual(Result.success, get(t, .viewport_active, @ptrCast(&viewport_active)));
    try testing.expect(!viewport_active);
    {
        const str = try zt.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1\n2", str);
    }

    // An absolute row within the scrollback becomes the first visible
    // row and round-trips through the scrollbar offset.
    scroll_viewport(t, .{ .tag = .row, .value = .{ .row = 1 } });
    {
        const str = try zt.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("2\n3", str);
    }
    var scrollbar_data: TerminalScrollbar = undefined;
    try testing.expectEqual(Result.success, get(t, .scrollbar, @ptrCast(&scrollbar_data)));
    try testing.expectEqual(@as(u64, 4), scrollbar_data.total);
    try testing.expectEqual(@as(u64, 1), scrollbar_data.offset);
    try testing.expectEqual(@as(u64, 2), scrollbar_data.len);

    // A row past the end clamps to the active area.
    scroll_viewport(t, .{ .tag = .row, .value = .{ .row = 9999 } });
    try testing.expectEqual(Result.success, get(t, .viewport_active, @ptrCast(&viewport_active)));
    try testing.expect(viewport_active);
    {
        const str = try zt.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("3\n4", str);
    }
    try testing.expectEqual(Result.success, get(t, .scrollbar, @ptrCast(&scrollbar_data)));
    try testing.expectEqual(@as(u64, 2), scrollbar_data.offset);
}

test "scroll_viewport row alt screen" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        5,
        2,
    ));
    defer free(t);

    // Enter the alternate screen, which has no scrollback.
    vt_write(t, "\x1b[?1049h", 8);
    var screen: TerminalScreen = undefined;
    try testing.expectEqual(Result.success, get(t, .active_screen, @ptrCast(&screen)));
    try testing.expectEqual(TerminalScreen.alternate, screen);

    // Scrolling to any row keeps the viewport on the active area.
    var viewport_active: bool = false;
    scroll_viewport(t, .{ .tag = .row, .value = .{ .row = 0 } });
    try testing.expectEqual(Result.success, get(t, .viewport_active, @ptrCast(&viewport_active)));
    try testing.expect(viewport_active);
    scroll_viewport(t, .{ .tag = .row, .value = .{ .row = 9999 } });
    try testing.expectEqual(Result.success, get(t, .viewport_active, @ptrCast(&viewport_active)));
    try testing.expect(viewport_active);

    // With no scrollback the scrollbar covers exactly the active area.
    var scrollbar_data: TerminalScrollbar = undefined;
    try testing.expectEqual(Result.success, get(t, .scrollbar, @ptrCast(&scrollbar_data)));
    try testing.expectEqual(@as(u64, 2), scrollbar_data.total);
    try testing.expectEqual(@as(u64, 0), scrollbar_data.offset);
    try testing.expectEqual(@as(u64, 2), scrollbar_data.len);
}

test "scroll_viewport null" {
    scroll_viewport(null, .{ .tag = .top, .value = undefined });
    scroll_viewport(null, .{ .tag = .row, .value = .{ .row = 1 } });
}

test "compression invalid arguments" {
    var activity: u64 = undefined;
    var compression_result: CompressionResult = undefined;

    try testing.expectEqual(
        Result.invalid_value,
        compression_activity(null, &activity),
    );
    try testing.expectEqual(
        Result.invalid_value,
        compress(null, @intFromEnum(CompressionMode.incremental), &compression_result),
    );

    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    try testing.expectEqual(
        Result.invalid_value,
        compression_activity(t, null),
    );
    try testing.expectEqual(
        Result.invalid_value,
        compress(t, @intFromEnum(CompressionMode.incremental), null),
    );
    try testing.expectEqual(
        Result.invalid_value,
        compress(t, -1, &compression_result),
    );
}

test "compression activity and incremental scheduling" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    var initial_activity: u64 = undefined;
    try testing.expectEqual(
        Result.success,
        compression_activity(t, &initial_activity),
    );

    const line = "repeated and compressible terminal history\r\n";
    const repeat = 4_000;
    const input = try testing.allocator.alloc(u8, line.len * repeat);
    defer testing.allocator.free(input);
    for (0..repeat) |i|
        @memcpy(input[i * line.len ..][0..line.len], line);
    vt_write(t, input.ptr, input.len);

    var activity: u64 = undefined;
    try testing.expectEqual(
        Result.success,
        compression_activity(t, &activity),
    );
    try testing.expect(activity != initial_activity);

    var compression_result: CompressionResult = undefined;
    for (0..1_000) |_| {
        try testing.expectEqual(
            Result.success,
            compress(
                t,
                @intFromEnum(CompressionMode.incremental),
                &compression_result,
            ),
        );

        switch (compression_result) {
            .pending => continue,
            .complete => break,
            .unsupported => unreachable,
        }
    } else return error.TestUnexpectedResult;

    // Compression changes storage representation, not the activity token.
    var final_activity: u64 = undefined;
    try testing.expectEqual(
        Result.success,
        compression_activity(t, &final_activity),
    );
    try testing.expectEqual(activity, final_activity);

    try testing.expectEqual(
        Result.success,
        compress(t, @intFromEnum(CompressionMode.full), &compression_result),
    );
    try testing.expectEqual(CompressionResult.complete, compression_result);
}

test "reset" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    vt_write(t, "Hello", 5);
    reset(t);

    const str = try t.?.terminal.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("", str);
}

test "reset null" {
    reset(null);
}

test "resize" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    try testing.expectEqual(Result.success, resize(t, 40, 12, 9, 18));
    try testing.expectEqual(40, t.?.terminal.cols);
    try testing.expectEqual(12, t.?.terminal.rows);
}

test "resize null" {
    try testing.expectEqual(Result.invalid_value, resize(null, 80, 24, 9, 18));
}

test "resize invalid value" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    try testing.expectEqual(Result.invalid_value, resize(t, 0, 24, 9, 18));
    try testing.expectEqual(Result.invalid_value, resize(t, 80, 0, 9, 18));
}

test "resize shrinks both axes with cursor at bottom" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    // CSI 24;1H -> park the cursor on the bottom row (1-based).
    const move = "\x1b[24;1H";
    vt_write(t, move, move.len);

    // Shrink both axes; pre-resize cursor.y sits past the new bottom row.
    // Previously this underflowed in PageList.resizeCols.
    try testing.expectEqual(Result.success, resize(t, 79, 23, 8, 16));
    try testing.expectEqual(79, t.?.terminal.cols);
    try testing.expectEqual(23, t.?.terminal.rows);
}

test "set and get mode" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    // DEC mode 25 (cursor_visible) defaults to true
    const cursor_visible: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 25, .ansi = false });
    var config: ModeConfig = .{ .mode = cursor_visible, .value = undefined };
    try testing.expectEqual(Result.success, get(t, .mode, @ptrCast(&config)));
    try testing.expect(config.value);

    // Set it to false
    config.value = false;
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&config)));
    try testing.expectEqual(Result.success, get(t, .mode, @ptrCast(&config)));
    try testing.expect(!config.value);

    // ANSI mode 4 (insert) defaults to false
    const insert: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 4, .ansi = true });
    config.mode = insert;
    try testing.expectEqual(Result.success, get(t, .mode, @ptrCast(&config)));
    try testing.expect(!config.value);

    config.value = true;
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&config)));
    try testing.expectEqual(Result.success, get(t, .mode, @ptrCast(&config)));
    try testing.expect(config.value);
}

test "set mode default updates current and reset value" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const tag: modes.ModeTag.Backing = @bitCast(modes.ModeTag{
        .value = 2027,
        .ansi = false,
    });
    var config: ModeConfig = .{ .mode = tag, .value = true };
    try testing.expectEqual(Result.success, set(
        t,
        .mode_default,
        @ptrCast(&config),
    ));
    try testing.expect(t.?.terminal.modes.get(.grapheme_cluster));
    try testing.expect(t.?.terminal.modes.default.grapheme_cluster);

    config.value = false;
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&config)));
    try testing.expect(!t.?.terminal.modes.get(.grapheme_cluster));
    try testing.expect(t.?.terminal.modes.default.grapheme_cluster);

    // Setting the default also unconditionally replaces the current value.
    config.value = true;
    try testing.expectEqual(Result.success, set(
        t,
        .mode_default,
        @ptrCast(&config),
    ));
    try testing.expect(t.?.terminal.modes.get(.grapheme_cluster));

    config.value = false;
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&config)));
    vt_write(t, "\x1bc", 2);
    try testing.expect(t.?.terminal.modes.get(.grapheme_cluster));

    config.value = false;
    try testing.expectEqual(Result.success, set(
        t,
        .mode_default,
        @ptrCast(&config),
    ));
    try testing.expect(!t.?.terminal.modes.get(.grapheme_cluster));
    try testing.expect(!t.?.terminal.modes.default.grapheme_cluster);
}

test "set mode default validates configuration" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    try testing.expectEqual(Result.invalid_value, set(
        t,
        .mode_default,
        null,
    ));

    var config: ModeConfig = .{
        .mode = @bitCast(modes.ModeTag{ .value = 9999, .ansi = false }),
        .value = true,
    };
    try testing.expectEqual(Result.invalid_value, set(
        t,
        .mode_default,
        @ptrCast(&config),
    ));

    config.mode = @bitCast(modes.ModeTag{ .value = 1047, .ansi = false });
    try testing.expectEqual(Result.invalid_value, set(
        t,
        .mode_default,
        @ptrCast(&config),
    ));
}

test "set and get mode null" {
    const tag: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 25, .ansi = false });
    var config: ModeConfig = .{ .mode = tag, .value = true };
    try testing.expectEqual(Result.invalid_value, set(null, .mode, @ptrCast(&config)));
    try testing.expectEqual(Result.invalid_value, get(null, .mode, @ptrCast(&config)));
}

test "set and get mode validate configuration" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    try testing.expectEqual(Result.invalid_value, set(t, .mode, null));
    try testing.expectEqual(Result.invalid_value, get(t, .mode, null));

    var config: ModeConfig = .{
        .mode = @bitCast(modes.ModeTag{ .value = 9999, .ansi = false }),
        .value = true,
    };
    try testing.expectEqual(Result.invalid_value, set(t, .mode, @ptrCast(&config)));
    try testing.expectEqual(Result.invalid_value, get(t, .mode, @ptrCast(&config)));
}

test "vt_write" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    vt_write(t, "Hello", 5);

    const str = try t.?.terminal.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Hello", str);
}

test "vt_write split escape sequence" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    // Write "Hello" in bold by splitting the CSI bold sequence across two writes.
    // ESC [ 1 m  = bold on, ESC [ 0 m = reset
    // Split ESC from the rest of the CSI sequence.
    vt_write(t, "Hello \x1b", 7);
    vt_write(t, "[1mBold\x1b[0m", 10);

    const str = try t.?.terminal.plainString(testing.allocator);
    defer testing.allocator.free(str);
    // If the escape sequence leaked, we'd see "[1mBold" as literal text.
    try testing.expectEqualStrings("Hello Bold", str);
}

test "vt_write split combining mark after base at right edge" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        2,
        2,
    ));
    defer free(t);

    // Put "å" in the final column, then send its combining low line in a
    // separate write so the mark arrives while the cursor has a pending wrap.
    vt_write(t, "xå", 3);
    vt_write(t, "\xcc\xb2", 2);

    const str = try t.?.terminal.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("xå̲", str);
}

test "get cols and rows" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    var cols: size.CellCountInt = undefined;
    var rows: size.CellCountInt = undefined;
    try testing.expectEqual(Result.success, get(t, .cols, @ptrCast(&cols)));
    try testing.expectEqual(Result.success, get(t, .rows, @ptrCast(&rows)));
    try testing.expectEqual(80, cols);
    try testing.expectEqual(24, rows);
}

test "get cursor position" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    vt_write(t, "Hello", 5);

    var x: size.CellCountInt = undefined;
    var y: size.CellCountInt = undefined;
    try testing.expectEqual(Result.success, get(t, .cursor_x, @ptrCast(&x)));
    try testing.expectEqual(Result.success, get(t, .cursor_y, @ptrCast(&y)));
    try testing.expectEqual(5, x);
    try testing.expectEqual(0, y);
}

test "get vt_processing_error" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    var processing_error: bool = true;
    try testing.expectEqual(Result.success, get(
        t,
        .vt_processing_error,
        @ptrCast(&processing_error),
    ));
    try testing.expect(!processing_error);

    // Force a non-graceful terminal-owned update failure through the public
    // VT write path.
    {
        const alloc = t.?.terminal.screens.active.alloc;
        t.?.terminal.screens.active.alloc = testing.failing_allocator;
        defer t.?.terminal.screens.active.alloc = alloc;

        const input = "\x1B]2;unavailable\x1B\\";
        vt_write(t, input, input.len);
    }

    try testing.expectEqual(Result.success, get(
        t,
        .vt_processing_error,
        @ptrCast(&processing_error),
    ));
    try testing.expect(processing_error);

    reset(t);
    try testing.expectEqual(Result.success, get(
        t,
        .vt_processing_error,
        @ptrCast(&processing_error),
    ));
    try testing.expect(processing_error);
}

test "get null" {
    var cols: size.CellCountInt = undefined;
    try testing.expectEqual(Result.invalid_value, get(null, .cols, @ptrCast(&cols)));
}

test "get cursor_visible" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    var visible: bool = undefined;
    try testing.expectEqual(Result.success, get(t, .cursor_visible, @ptrCast(&visible)));
    try testing.expect(visible);

    // DEC mode 25 controls cursor visibility
    var config: ModeConfig = .{
        .mode = @bitCast(modes.ModeTag{ .value = 25, .ansi = false }),
        .value = false,
    };
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&config)));
    try testing.expectEqual(Result.success, get(t, .cursor_visible, @ptrCast(&visible)));
    try testing.expect(!visible);
}

test "get active_screen" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    var screen: TerminalScreen = undefined;
    try testing.expectEqual(Result.success, get(t, .active_screen, @ptrCast(&screen)));
    try testing.expectEqual(.primary, screen);
}

test "get kitty_keyboard_flags" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    var flags: u8 = undefined;
    try testing.expectEqual(Result.success, get(t, .kitty_keyboard_flags, @ptrCast(&flags)));
    try testing.expectEqual(0, flags);

    // Push kitty flags via VT sequence: CSI > 3 u (push disambiguate | report_events)
    vt_write(t, "\x1b[>3u", 5);

    try testing.expectEqual(Result.success, get(t, .kitty_keyboard_flags, @ptrCast(&flags)));
    try testing.expectEqual(3, flags);
}

test "get mouse_tracking" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    var tracking: bool = undefined;
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(!tracking);

    // Enable X10 mouse (DEC mode 9)
    var config: ModeConfig = .{
        .mode = @bitCast(modes.ModeTag{ .value = 9, .ansi = false }),
        .value = true,
    };
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&config)));
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(tracking);

    // Disable X10, enable normal mouse (DEC mode 1000)
    config.value = false;
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&config)));
    config = .{
        .mode = @bitCast(modes.ModeTag{ .value = 1000, .ansi = false }),
        .value = true,
    };
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&config)));
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(tracking);

    // Disable normal, enable button mouse (DEC mode 1002)
    config.value = false;
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&config)));
    config = .{
        .mode = @bitCast(modes.ModeTag{ .value = 1002, .ansi = false }),
        .value = true,
    };
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&config)));
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(tracking);

    // Disable button, enable any mouse (DEC mode 1003)
    config.value = false;
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&config)));
    config = .{
        .mode = @bitCast(modes.ModeTag{ .value = 1003, .ansi = false }),
        .value = true,
    };
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&config)));
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(tracking);

    // Disable all - should be false again
    config.value = false;
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&config)));
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(!tracking);
}

test "get total_rows" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    var total: usize = undefined;
    try testing.expectEqual(Result.success, get(t, .total_rows, @ptrCast(&total)));
    try testing.expect(total >= 24);
}

test "get scrollback_rows" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        3,
    ));
    defer free(t);

    var scrollback: usize = undefined;
    try testing.expectEqual(Result.success, get(t, .scrollback_rows, @ptrCast(&scrollback)));
    try testing.expectEqual(@as(usize, 0), scrollback);

    // Write enough lines to push content into scrollback
    vt_write(t, "line1\r\nline2\r\nline3\r\nline4\r\nline5\r\n", 34);

    try testing.expectEqual(Result.success, get(t, .scrollback_rows, @ptrCast(&scrollback)));
    try testing.expectEqual(@as(usize, 2), scrollback);
}

test "get configured scrollback limits" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        3,
    ));
    defer free(t);

    var value: usize = undefined;
    try testing.expectEqual(
        Result.success,
        get(t, .scrollback_max_bytes, @ptrCast(&value)),
    );
    try testing.expectEqual(@as(usize, 10_000), value);
    try testing.expectEqual(
        Result.no_value,
        get(t, .scrollback_max_lines, @ptrCast(&value)),
    );

    const max_bytes: usize = 0;
    const max_lines: usize = 12;
    try testing.expectEqual(
        Result.success,
        set(t, .scrollback_max_bytes, &max_bytes),
    );
    try testing.expectEqual(
        Result.success,
        set(t, .scrollback_max_lines, &max_lines),
    );
    try testing.expectEqual(
        Result.success,
        get(t, .scrollback_max_bytes, @ptrCast(&value)),
    );
    try testing.expectEqual(max_bytes, value);
    try testing.expectEqual(
        Result.success,
        get(t, .scrollback_max_lines, @ptrCast(&value)),
    );
    try testing.expectEqual(max_lines, value);

    // The configured limits belong to the primary screen and remain
    // readable while an alternate screen is active.
    vt_write(t, "\x1b[?1049h", 8);
    try testing.expectEqual(
        Result.success,
        get(t, .scrollback_max_bytes, @ptrCast(&value)),
    );
    try testing.expectEqual(max_bytes, value);
    try testing.expectEqual(
        Result.success,
        get(t, .scrollback_max_lines, @ptrCast(&value)),
    );
    try testing.expectEqual(max_lines, value);

    try testing.expectEqual(
        Result.success,
        set(t, .scrollback_max_bytes, null),
    );
    try testing.expectEqual(
        Result.success,
        set(t, .scrollback_max_lines, null),
    );
    try testing.expectEqual(
        Result.no_value,
        get(t, .scrollback_max_bytes, @ptrCast(&value)),
    );
    try testing.expectEqual(
        Result.no_value,
        get(t, .scrollback_max_lines, @ptrCast(&value)),
    );
}

test "get invalid" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    try testing.expectEqual(Result.invalid_value, get(t, .invalid, null));
}

test "set default cursor style and blink" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    var default_style: TerminalCursorStyle = .bar;
    var default_blink = true;
    try testing.expectEqual(Result.success, set(t, .default_cursor_style, @ptrCast(&default_style)));
    try testing.expectEqual(Result.success, set(t, .default_cursor_blink, @ptrCast(&default_blink)));

    // Setting defaults applies them immediately while the cursor is still default.
    try testing.expectEqual(Screen.CursorStyle.bar, t.?.terminal.screens.active.cursor.cursor_style);
    try testing.expect(t.?.terminal.modes.get(.cursor_blinking));

    // An explicit DECSCUSR style overrides the configured defaults.
    vt_write(t, "\x1b[2 q", 5);
    try testing.expectEqual(Screen.CursorStyle.block, t.?.terminal.screens.active.cursor.cursor_style);
    try testing.expect(!t.?.terminal.modes.get(.cursor_blinking));

    // Changing defaults does not override an explicit cursor style.
    default_style = .underline;
    try testing.expectEqual(Result.success, set(t, .default_cursor_style, @ptrCast(&default_style)));
    try testing.expectEqual(Screen.CursorStyle.block, t.?.terminal.screens.active.cursor.cursor_style);
    try testing.expect(!t.?.terminal.modes.get(.cursor_blinking));

    // DECSCUSR reset restores the configured default style and blink.
    vt_write(t, "\x1b[0 q", 5);
    try testing.expectEqual(Screen.CursorStyle.underline, t.?.terminal.screens.active.cursor.cursor_style);
    try testing.expect(t.?.terminal.modes.get(.cursor_blinking));

    // RIS also restores cursor defaults from Terminal-owned state.
    vt_write(t, "\x1b[2 q", 5);
    reset(t);
    try testing.expectEqual(Screen.CursorStyle.underline, t.?.terminal.screens.active.cursor.cursor_style);
    try testing.expect(t.?.terminal.modes.get(.cursor_blinking));
}

test "set and get selection" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    vt_write(t, "Hello", 5);

    var start_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 0, .y = 0 } },
    }, &start_ref));

    var end_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 4, .y = 0 } },
    }, &end_ref));

    var out: selection_c.CSelection = undefined;
    try testing.expectEqual(Result.no_value, get(t, .selection, @ptrCast(&out)));

    const sel: selection_c.CSelection = .{
        .start = start_ref,
        .end = end_ref,
        .rectangle = true,
    };
    try testing.expectEqual(Result.success, set(t, .selection, @ptrCast(&sel)));
    try testing.expect(t.?.terminal.screens.active.selection.?.tracked());

    try testing.expectEqual(Result.success, get(t, .selection, @ptrCast(&out)));
    try testing.expect(out.start.toPin().?.eql(start_ref.toPin().?));
    try testing.expect(out.end.toPin().?.eql(end_ref.toPin().?));
    try testing.expect(out.rectangle);

    try testing.expectEqual(Result.success, set(t, .selection, null));
    try testing.expect(t.?.terminal.screens.active.selection == null);
    try testing.expectEqual(Result.no_value, get(t, .selection, @ptrCast(&out)));
}

test "selection derivation helpers" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    vt_write(t, "  Hello  \r\nWorld", 16);

    var out: selection_c.CSelection = undefined;

    var word_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 3, .y = 0 } },
    }, &word_ref));

    var empty_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 20, .y = 0 } },
    }, &empty_ref));

    var line_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 0, .y = 0 } },
    }, &line_ref));

    var word_opts: selection_c.SelectWordOptions = .{
        .ref = word_ref,
    };
    try testing.expectEqual(Result.success, selection_c.word(t, &word_opts, &out));
    try testing.expectEqual(@as(u16, 2), out.start.toPin().?.x);
    try testing.expectEqual(@as(u16, 6), out.end.toPin().?.x);

    word_opts.ref = empty_ref;
    try testing.expectEqual(Result.no_value, selection_c.word(t, &word_opts, &out));

    var between_start_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 20, .y = 1 } },
    }, &between_start_ref));

    var between_end_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 0, .y = 1 } },
    }, &between_end_ref));

    var word_between_opts: selection_c.SelectWordBetweenOptions = .{
        .start = between_start_ref,
        .end = between_end_ref,
    };
    try testing.expectEqual(Result.success, selection_c.word_between(t, &word_between_opts, &out));
    try testing.expectEqual(@as(u16, 0), out.start.toPin().?.x);
    try testing.expectEqual(@as(u16, 1), out.start.toPin().?.y);
    try testing.expectEqual(@as(u16, 4), out.end.toPin().?.x);
    try testing.expectEqual(@as(u16, 1), out.end.toPin().?.y);

    var line_opts: selection_c.SelectLineOptions = .{
        .ref = line_ref,
    };
    try testing.expectEqual(Result.success, selection_c.line(t, &line_opts, &out));
    try testing.expectEqual(@as(u16, 2), out.start.toPin().?.x);
    try testing.expectEqual(@as(u16, 6), out.end.toPin().?.x);

    try testing.expectEqual(Result.success, selection_c.all(t, &out));
    try testing.expectEqual(@as(u16, 2), out.start.toPin().?.x);
    try testing.expectEqual(@as(u16, 0), out.start.toPin().?.y);
    try testing.expectEqual(@as(u16, 4), out.end.toPin().?.x);
    try testing.expectEqual(@as(u16, 1), out.end.toPin().?.y);

    try testing.expectEqual(Result.no_value, selection_c.output(t, line_ref, &out));

    line_opts.size = @sizeOf(usize) - 1;
    try testing.expectEqual(Result.invalid_value, selection_c.line(t, &line_opts, &out));
    try testing.expectEqual(Result.invalid_value, selection_c.word(t, null, &out));
    try testing.expectEqual(Result.invalid_value, selection_c.word(t, &word_opts, null));
    try testing.expectEqual(Result.invalid_value, selection_c.word_between(t, null, &out));
    try testing.expectEqual(Result.invalid_value, selection_c.word_between(t, &word_between_opts, null));
}

test "selection_adjust mutates snapshot end" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    vt_write(t, "Hello", 5);

    var start_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 0, .y = 0 } },
    }, &start_ref));

    var end_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 1, .y = 0 } },
    }, &end_ref));

    var sel: selection_c.CSelection = .{
        .start = start_ref,
        .end = end_ref,
    };
    try testing.expectEqual(Result.success, selection_c.adjust(t, &sel, .right));
    try testing.expectEqual(@as(u16, 0), sel.start.toPin().?.x);
    try testing.expectEqual(@as(u16, 2), sel.end.toPin().?.x);

    try testing.expectEqual(Result.success, selection_c.adjust(t, &sel, .left));
    try testing.expectEqual(@as(u16, 0), sel.start.toPin().?.x);
    try testing.expectEqual(@as(u16, 1), sel.end.toPin().?.x);

    sel = .{
        .start = end_ref,
        .end = start_ref,
    };
    try testing.expectEqual(Result.success, selection_c.adjust(t, &sel, .right));
    try testing.expectEqual(@as(u16, 1), sel.start.toPin().?.x);
    try testing.expectEqual(@as(u16, 1), sel.end.toPin().?.x);
}

test "selection_order and selection_ordered" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    vt_write(t, "Hello\r\nWorld", 12);

    var start_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 3, .y = 0 } },
    }, &start_ref));

    var end_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 1, .y = 1 } },
    }, &end_ref));

    const sel: selection_c.CSelection = .{
        .start = start_ref,
        .end = end_ref,
        .rectangle = true,
    };

    var order: selection_c.Order = undefined;
    try testing.expectEqual(Result.success, selection_c.order(t, &sel, &order));
    try testing.expectEqual(selection_c.Order.mirrored_forward, order);

    var out: selection_c.CSelection = undefined;
    try testing.expectEqual(Result.success, selection_c.ordered(t, &sel, .forward, &out));
    try testing.expectEqual(@as(u16, 1), out.start.toPin().?.x);
    try testing.expectEqual(@as(u16, 0), out.start.toPin().?.y);
    try testing.expectEqual(@as(u16, 3), out.end.toPin().?.x);
    try testing.expectEqual(@as(u16, 1), out.end.toPin().?.y);
    try testing.expect(out.rectangle);

    try testing.expectEqual(Result.success, selection_c.ordered(t, &sel, .reverse, &out));
    try testing.expectEqual(@as(u16, 3), out.start.toPin().?.x);
    try testing.expectEqual(@as(u16, 1), out.start.toPin().?.y);
    try testing.expectEqual(@as(u16, 1), out.end.toPin().?.x);
    try testing.expectEqual(@as(u16, 0), out.end.toPin().?.y);
    try testing.expect(out.rectangle);
}

test "selection_contains" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    vt_write(t, "Hello\r\nWorld", 12);

    var start_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 3, .y = 0 } },
    }, &start_ref));

    var end_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 1, .y = 1 } },
    }, &end_ref));

    const linear: selection_c.CSelection = .{
        .start = start_ref,
        .end = end_ref,
    };

    var contains: bool = undefined;
    try testing.expectEqual(Result.success, selection_c.contains(t, &linear, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 4, .y = 0 } },
    }, &contains));
    try testing.expect(contains);

    try testing.expectEqual(Result.success, selection_c.contains(t, &linear, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 2, .y = 0 } },
    }, &contains));
    try testing.expect(!contains);

    const rectangle: selection_c.CSelection = .{
        .start = start_ref,
        .end = end_ref,
        .rectangle = true,
    };

    try testing.expectEqual(Result.success, selection_c.contains(t, &rectangle, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 2, .y = 0 } },
    }, &contains));
    try testing.expect(contains);
}

test "selection_equal" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    var other_t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &other_t,
        80,
        24,
    ));
    defer free(other_t);

    vt_write(t, "Hello", 5);
    vt_write(other_t, "Hello", 5);

    var start_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 0, .y = 0 } },
    }, &start_ref));

    var end_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 1, .y = 0 } },
    }, &end_ref));

    var other_end_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 2, .y = 0 } },
    }, &other_end_ref));

    var cross_terminal_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(other_t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 1, .y = 0 } },
    }, &cross_terminal_ref));

    const sel: selection_c.CSelection = .{
        .start = start_ref,
        .end = end_ref,
    };
    const equal_sel: selection_c.CSelection = .{
        .start = start_ref,
        .end = end_ref,
    };
    const different_endpoint: selection_c.CSelection = .{
        .start = start_ref,
        .end = other_end_ref,
    };
    const different_rectangle: selection_c.CSelection = .{
        .start = start_ref,
        .end = end_ref,
        .rectangle = true,
    };
    const cross_terminal: selection_c.CSelection = .{
        .start = start_ref,
        .end = cross_terminal_ref,
    };

    var equal: bool = undefined;
    try testing.expectEqual(Result.success, selection_c.equal(t, &sel, &equal_sel, &equal));
    try testing.expect(equal);

    try testing.expectEqual(Result.success, selection_c.equal(t, &sel, &different_endpoint, &equal));
    try testing.expect(!equal);

    try testing.expectEqual(Result.success, selection_c.equal(t, &sel, &different_rectangle, &equal));
    try testing.expect(!equal);

    try testing.expectEqual(Result.success, selection_c.equal(t, &sel, &cross_terminal, &equal));
    try testing.expect(!equal);
    try testing.expectEqual(Result.invalid_value, selection_c.equal(t, &sel, &equal_sel, null));
}

test "selection_order invalid values" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    var order: selection_c.Order = undefined;
    try testing.expectEqual(Result.invalid_value, selection_c.order(null, null, &order));
    try testing.expectEqual(Result.invalid_value, selection_c.order(t, null, &order));
}

test "grid_ref" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    vt_write(t, "Hello", 5);

    var out_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 0, .y = 0 } },
    }, &out_ref));

    // Extract cell from grid ref and verify it contains 'H'
    var out_cell: cell_c.CCell = undefined;
    try testing.expectEqual(Result.success, grid_ref_c.grid_ref_cell(&out_ref, &out_cell));

    var cp: u32 = 0;
    try testing.expectEqual(Result.success, cell_c.get(out_cell, .codepoint, @ptrCast(&cp)));
    try testing.expectEqual(@as(u32, 'H'), cp);
}

test "grid_ref null terminal" {
    var out_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.invalid_value, grid_ref(null, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 0, .y = 0 } },
    }, &out_ref));
}

test "point_from_grid_ref roundtrip active" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    vt_write(t, "Hello", 5);

    // Get a grid ref at (2, 0) in active coords
    var ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 2, .y = 0 } },
    }, &ref));

    // Convert back to active coords
    var coord: point.Coordinate = undefined;
    try testing.expectEqual(Result.success, point_from_grid_ref(t, &ref, .active, &coord));
    try testing.expectEqual(@as(size.CellCountInt, 2), coord.x);
    try testing.expectEqual(@as(u32, 0), coord.y);
}

test "point_from_grid_ref roundtrip viewport" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    vt_write(t, "Hello", 5);

    var ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .viewport,
        .value = .{ .viewport = .{ .x = 0, .y = 0 } },
    }, &ref));

    var coord: point.Coordinate = undefined;
    try testing.expectEqual(Result.success, point_from_grid_ref(t, &ref, .viewport, &coord));
    try testing.expectEqual(@as(size.CellCountInt, 0), coord.x);
    try testing.expectEqual(@as(u32, 0), coord.y);
}

test "point_from_grid_ref history ref to active returns no_value" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        4,
    ));
    defer free(t);

    // Write enough lines to push content into scrollback
    for (0..10) |_| {
        vt_write(t, "line\n", 5);
    }

    // Get a ref to the first line (now in scrollback)
    var ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .screen,
        .value = .{ .screen = .{ .x = 0, .y = 0 } },
    }, &ref));

    // Should succeed for screen coords
    var coord: point.Coordinate = undefined;
    try testing.expectEqual(Result.success, point_from_grid_ref(t, &ref, .screen, &coord));
    try testing.expectEqual(@as(u32, 0), coord.y);

    // Should fail for active coords (it's in scrollback)
    try testing.expectEqual(Result.no_value, point_from_grid_ref(t, &ref, .active, &coord));
}

test "point_from_grid_ref null terminal" {
    var ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.invalid_value, point_from_grid_ref(null, &ref, .active, null));
}

test "point_from_grid_ref null node" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.invalid_value, point_from_grid_ref(t, &ref, .active, null));
}

test "set write_pty callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;
        var last_userdata: ?*anyopaque = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
            last_userdata = null;
        }

        fn writePty(_: Terminal, ud: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
            last_userdata = ud;
        }
    };
    defer S.deinit();

    // Set userdata and write_pty callback
    var sentinel: u8 = 42;
    try testing.expectEqual(Result.success, set(t, .userdata, @ptrCast(&sentinel)));
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));

    // DECRQM for wraparound mode (mode 7, set by default) should trigger write_pty
    vt_write(t, "\x1B[?7$p", 6);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1B[?7;1$y", S.last_data.?);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);
}

test "write_pty receives DECRQSS response" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |data| testing.allocator.free(data);
            last_data = null;
        }

        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |data| testing.allocator.free(data);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
    };
    defer S.deinit();

    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));

    const query = "\x1B[1m\x1BP$qm\x1B\\";
    vt_write(t, query, query.len);
    try testing.expectEqualStrings("\x1BP1$r0;1m\x1B\\", S.last_data.?);
}

test "write_pty receives OSC color query response" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }

        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
    };
    defer S.deinit();

    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));

    const set_fg = "\x1B]10;rgb:01/02/03\x1B\\";
    vt_write(t, set_fg, set_fg.len);
    try testing.expect(S.last_data == null);

    const query_fg = "\x1B]10;?\x1B\\";
    vt_write(t, query_fg, query_fg.len);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1B]10;rgb:0101/0202/0303\x1B\\", S.last_data.?);
}

test "set write_pty without callback ignores queries" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    // Without setting a callback, DECRQM should be silently ignored (no crash)
    vt_write(t, "\x1B[?7$p", 6);
}

test "set write_pty null clears callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const S = struct {
        var called: bool = false;
        fn writePty(_: Terminal, _: ?*anyopaque, _: [*]const u8, _: usize) callconv(lib.calling_conv) void {
            called = true;
        }
    };
    S.called = false;

    // Set then clear the callback
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .write_pty, null));

    vt_write(t, "\x1B[?7$p", 6);
    try testing.expect(!S.called);
}

test "set bell callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const S = struct {
        var bell_count: usize = 0;
        var last_userdata: ?*anyopaque = null;

        fn bell(_: Terminal, ud: ?*anyopaque) callconv(lib.calling_conv) void {
            bell_count += 1;
            last_userdata = ud;
        }
    };
    S.bell_count = 0;
    S.last_userdata = null;

    // Set userdata and bell callback
    var sentinel: u8 = 99;
    try testing.expectEqual(Result.success, set(t, .userdata, @ptrCast(&sentinel)));
    try testing.expectEqual(Result.success, set(t, .bell, @ptrCast(&S.bell)));

    // Single BEL
    vt_write(t, "\x07", 1);
    try testing.expectEqual(@as(usize, 1), S.bell_count);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);

    // Multiple BELs
    vt_write(t, "\x07\x07", 2);
    try testing.expectEqual(@as(usize, 3), S.bell_count);
}

test "bell without callback is silent" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    // BEL without a callback should not crash
    vt_write(t, "\x07", 1);
}

test "set enquiry callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }

        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }

        const response = "OK";
        fn enquiry(_: Terminal, _: ?*anyopaque) callconv(lib.calling_conv) lib.String {
            return .{ .ptr = response, .len = response.len };
        }
    };
    defer S.deinit();

    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .enquiry, @ptrCast(&S.enquiry)));

    // ENQ (0x05) should trigger the enquiry callback and write response via write_pty
    vt_write(t, "\x05", 1);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("OK", S.last_data.?);
}

test "enquiry without callback is silent" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    // ENQ without a callback should not crash
    vt_write(t, "\x05", 1);
}

test "set xtversion callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }

        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }

        const version = "myterm 1.0";
        fn xtversion(_: Terminal, _: ?*anyopaque) callconv(lib.calling_conv) lib.String {
            return .{ .ptr = version, .len = version.len };
        }
    };
    defer S.deinit();

    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .xtversion, @ptrCast(&S.xtversion)));

    // XTVERSION: CSI > q
    vt_write(t, "\x1B[>q", 4);
    try testing.expect(S.last_data != null);
    // Response should be DCS >| version ST
    try testing.expectEqualStrings("\x1BP>|myterm 1.0\x1B\\", S.last_data.?);
}

test "xtversion without callback reports default" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }

        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
    };
    defer S.deinit();

    // Set write_pty but not xtversion — should get default "libghostty"
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));

    vt_write(t, "\x1B[>q", 4);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1BP>|libghostty\x1B\\", S.last_data.?);
}

test "set title_changed callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const S = struct {
        var title_count: usize = 0;
        var last_userdata: ?*anyopaque = null;

        fn titleChanged(_: Terminal, ud: ?*anyopaque) callconv(lib.calling_conv) void {
            title_count += 1;
            last_userdata = ud;
        }
    };
    S.title_count = 0;
    S.last_userdata = null;

    var sentinel: u8 = 77;
    try testing.expectEqual(Result.success, set(t, .userdata, @ptrCast(&sentinel)));
    try testing.expectEqual(Result.success, set(t, .title_changed, @ptrCast(&S.titleChanged)));

    // OSC 2 ; title ST — set window title
    vt_write(t, "\x1B]2;Hello\x1B\\", 10);
    try testing.expectEqual(@as(usize, 1), S.title_count);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);

    // Another title change
    vt_write(t, "\x1B]2;World\x1B\\", 10);
    try testing.expectEqual(@as(usize, 2), S.title_count);
}

test "title_changed without callback is silent" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    // OSC 2 without a callback should not crash
    vt_write(t, "\x1B]2;Hello\x1B\\", 10);
}

test "set desktop_notification callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const S = struct {
        var count: usize = 0;
        var last_userdata: ?*anyopaque = null;
        var last_size: usize = 0;
        var title: [64]u8 = undefined;
        var title_len: usize = 0;
        var body: [64]u8 = undefined;
        var body_len: usize = 0;

        fn desktopNotification(
            _: Terminal,
            ud: ?*anyopaque,
            notification: *const DesktopNotification,
        ) callconv(lib.calling_conv) void {
            count += 1;
            last_userdata = ud;
            last_size = notification.size;
            title_len = notification.title.len;
            body_len = notification.body.len;
            @memcpy(title[0..title_len], notification.title.ptr[0..title_len]);
            @memcpy(body[0..body_len], notification.body.ptr[0..body_len]);
        }
    };
    S.count = 0;
    S.last_userdata = null;
    S.last_size = 0;
    S.title_len = 0;
    S.body_len = 0;

    var sentinel: u8 = 99;
    try testing.expectEqual(Result.success, set(t, .userdata, @ptrCast(&sentinel)));
    try testing.expectEqual(Result.success, set(
        t,
        .desktop_notification,
        @ptrCast(&S.desktopNotification),
    ));

    // Split OSC 777 across writes to exercise the persistent VT parser.
    const seq_a = "\x1B]777;notify;Codex;";
    const seq_b = "Needs attention\x1B\\";
    vt_write(t, seq_a, seq_a.len);
    try testing.expectEqual(@as(usize, 0), S.count);
    vt_write(t, seq_b, seq_b.len);
    try testing.expectEqual(@as(usize, 1), S.count);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);
    try testing.expectEqual(@sizeOf(DesktopNotification), S.last_size);
    try testing.expectEqualStrings("Codex", S.title[0..S.title_len]);
    try testing.expectEqualStrings("Needs attention", S.body[0..S.body_len]);

    // OSC 9 has no title and preserves its body.
    const seq_c = "\x1B]9;Build complete\x07";
    vt_write(t, seq_c, seq_c.len);
    try testing.expectEqual(@as(usize, 2), S.count);
    try testing.expectEqualStrings("", S.title[0..S.title_len]);
    try testing.expectEqualStrings("Build complete", S.body[0..S.body_len]);

    // Removing the callback takes effect immediately.
    try testing.expectEqual(Result.success, set(t, .desktop_notification, null));
    vt_write(t, seq_c, seq_c.len);
    try testing.expectEqual(@as(usize, 2), S.count);
}

test "set progress_report callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const S = struct {
        var count: usize = 0;
        var last_userdata: ?*anyopaque = null;
        var last_size: usize = 0;
        var last_state: ProgressState = .remove;
        var last_progress: i8 = -1;

        fn progressReport(
            _: Terminal,
            ud: ?*anyopaque,
            report: *const ProgressReport,
        ) callconv(lib.calling_conv) void {
            count += 1;
            last_userdata = ud;
            last_size = report.size;
            last_state = report.state;
            last_progress = report.progress;
        }
    };
    S.count = 0;
    S.last_userdata = null;
    S.last_size = 0;
    S.last_state = .remove;
    S.last_progress = -1;

    var sentinel: u8 = 100;
    try testing.expectEqual(Result.success, set(t, .userdata, @ptrCast(&sentinel)));
    try testing.expectEqual(Result.success, set(
        t,
        .progress_report,
        @ptrCast(&S.progressReport),
    ));

    const cases = [_]struct {
        sequence: []const u8,
        state: ProgressState,
        progress: i8,
    }{
        .{ .sequence = "\x1B]9;4;0;\x1B\\", .state = .remove, .progress = -1 },
        .{ .sequence = "\x1B]9;4;1;42\x07", .state = .set, .progress = 42 },
        .{ .sequence = "\x1B]9;4;2;7\x1B\\", .state = .@"error", .progress = 7 },
        .{ .sequence = "\x1B]9;4;3\x1B\\", .state = .indeterminate, .progress = -1 },
        .{ .sequence = "\x1B]9;4;4;75\x1B\\", .state = .pause, .progress = 75 },
    };

    for (cases, 1..) |case, expected_count| {
        const midpoint = case.sequence.len / 2;
        vt_write(t, case.sequence.ptr, midpoint);
        try testing.expectEqual(expected_count - 1, S.count);
        vt_write(t, case.sequence.ptr + midpoint, case.sequence.len - midpoint);
        try testing.expectEqual(expected_count, S.count);
        try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);
        try testing.expectEqual(@sizeOf(ProgressReport), S.last_size);
        try testing.expectEqual(case.state, S.last_state);
        try testing.expectEqual(case.progress, S.last_progress);
    }

    try testing.expectEqual(Result.success, set(t, .progress_report, null));
    const ignored = "\x1B]9;4;1;90\x1B\\";
    vt_write(t, ignored, ignored.len);
    try testing.expectEqual(@as(usize, cases.len), S.count);
}

test "set pwd_changed callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const S = struct {
        var pwd_count: usize = 0;
        var last_userdata: ?*anyopaque = null;

        fn pwdChanged(_: Terminal, ud: ?*anyopaque) callconv(lib.calling_conv) void {
            pwd_count += 1;
            last_userdata = ud;
        }
    };
    S.pwd_count = 0;
    S.last_userdata = null;

    var sentinel: u8 = 88;
    try testing.expectEqual(Result.success, set(t, .userdata, @ptrCast(&sentinel)));
    try testing.expectEqual(Result.success, set(t, .pwd_changed, @ptrCast(&S.pwdChanged)));

    // OSC 7 ; file:///tmp ST — report pwd
    const seq1 = "\x1B]7;file:///tmp\x1B\\";
    vt_write(t, seq1, seq1.len);
    try testing.expectEqual(@as(usize, 1), S.pwd_count);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);
    try testing.expectEqualStrings("file:///tmp", zigTerminal(t).?.getPwd().?);

    // Another pwd change
    const seq2 = "\x1B]7;file:///home/user\x1B\\";
    vt_write(t, seq2, seq2.len);
    try testing.expectEqual(@as(usize, 2), S.pwd_count);
    try testing.expectEqualStrings("file:///home/user", zigTerminal(t).?.getPwd().?);
}

test "set clipboard_write callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const S = struct {
        var count: usize = 0;
        var last_terminal: Terminal = null;
        var last_userdata: ?*anyopaque = null;
        var last_size: usize = 0;
        var last_location: clipboard.Location = .standard;
        var last_contents_null: bool = false;
        var last_contents_len: usize = 0;
        var last_mimes: [8][64]u8 = undefined;
        var last_mime_lens: [8]usize = @splat(0);
        var last_data: [8][64]u8 = undefined;
        var last_data_lens: [8]usize = @splat(0);
        var next_result: clipboard.WriteResult = .success;

        fn clipboardWrite(
            terminal_: Terminal,
            ud: ?*anyopaque,
            request: *const ClipboardWrite,
        ) callconv(lib.calling_conv) clipboard.WriteResult {
            count += 1;
            last_terminal = terminal_;
            last_userdata = ud;
            last_size = request.size;
            last_location = request.location;
            last_contents_null = request.contents == null;
            last_contents_len = request.contents_len;

            if (request.contents) |ptr| {
                for (ptr[0..@min(request.contents_len, last_mimes.len)], 0..) |content, i| {
                    last_mime_lens[i] = @min(content.mime.len, last_mimes[i].len);
                    @memcpy(
                        last_mimes[i][0..last_mime_lens[i]],
                        content.mime.ptr[0..last_mime_lens[i]],
                    );

                    last_data_lens[i] = @min(content.data.len, last_data[i].len);
                    @memcpy(
                        last_data[i][0..last_data_lens[i]],
                        content.data.ptr[0..last_data_lens[i]],
                    );
                }
            }

            return next_result;
        }
    };
    S.count = 0;
    S.last_terminal = null;
    S.last_userdata = null;
    S.next_result = .denied;

    var sentinel: u8 = 88;
    try testing.expectEqual(Result.success, set(t, .userdata, @ptrCast(&sentinel)));
    try testing.expectEqual(Result.success, set(t, .clipboard_write, @ptrCast(&S.clipboardWrite)));

    // Split OSC 52 write whose decoded payload contains an embedded NUL.
    const seq1_a = "\x1B]52;c;aGVs";
    const seq1_b = "bG8Ad29ybGQ=\x1B\\";
    vt_write(t, seq1_a, seq1_a.len);
    vt_write(t, seq1_b, seq1_b.len);
    try testing.expectEqual(@as(usize, 1), S.count);
    try testing.expectEqual(t, S.last_terminal);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);
    try testing.expectEqual(@sizeOf(ClipboardWrite), S.last_size);
    try testing.expectEqual(clipboard.Location.standard, S.last_location);
    try testing.expect(!S.last_contents_null);
    try testing.expectEqual(@as(usize, 1), S.last_contents_len);
    try testing.expectEqualStrings("text/plain", S.last_mimes[0][0..S.last_mime_lens[0]]);
    try testing.expectEqualSlices(u8, "hello\x00world", S.last_data[0][0..S.last_data_lens[0]]);

    // OSC 52 destinations are normalized rather than exposed as wire bytes.
    const location_cases = [_]struct {
        selector: u8,
        expected: clipboard.Location,
    }{
        .{ .selector = 's', .expected = .selection },
        .{ .selector = 'p', .expected = .primary },
        .{ .selector = 'q', .expected = .standard },
    };
    for (location_cases) |case| {
        const seq = [_]u8{ '\x1B', ']', '5', '2', ';', case.selector, ';', 'e', 'A', '=', '=', '\x1B', '\\' };
        vt_write(t, &seq, seq.len);
        try testing.expectEqual(case.expected, S.last_location);
    }
    try testing.expectEqual(@as(usize, 4), S.count);

    // An empty content list is a clear and retains a null descriptor pointer.
    const clear = "\x1B]52;s;\x1B\\";
    vt_write(t, clear, clear.len);
    try testing.expectEqual(@as(usize, 5), S.count);
    try testing.expectEqual(clipboard.Location.selection, S.last_location);
    try testing.expect(S.last_contents_null);
    try testing.expectEqual(@as(usize, 0), S.last_contents_len);

    // Read requests and malformed base64 must never reach the callback.
    const read = "\x1B]52;c;?\x1B\\";
    vt_write(t, read, read.len);
    const malformed = "\x1B]52;c;%%%\x1B\\";
    vt_write(t, malformed, malformed.len);
    try testing.expectEqual(@as(usize, 5), S.count);

    // iTerm2 Copy reaches the same normalized callback.
    const iterm = "\x1B]1337;Copy=:aVRlcm0=\x1B\\";
    vt_write(t, iterm, iterm.len);
    try testing.expectEqual(@as(usize, 6), S.count);
    try testing.expectEqual(clipboard.Location.standard, S.last_location);
    try testing.expectEqualStrings("text/plain", S.last_mimes[0][0..S.last_mime_lens[0]]);
    try testing.expectEqualStrings("iTerm", S.last_data[0][0..S.last_data_lens[0]]);

    // Every representation is converted, and callback results propagate
    // through the C trampoline for protocols that can acknowledge writes.
    const internal_contents = [_]clipboard.Content{
        .{ .mime = "text/plain", .data = "plain" },
        .{ .mime = "application/octet-stream", .data = "a\x00b" },
        .{ .mime = "text/html", .data = "<b>plain</b>" },
        .{ .mime = "text/rtf", .data = "{\\rtf1 plain}" },
        .{ .mime = "image/png", .data = "\x89PNG" },
    };
    S.next_result = .busy;
    const handler = &t.?.stream.handler;
    const write_result = handler.effects.clipboard_write.?(handler, .{
        .location = .primary,
        .contents = &internal_contents,
    });
    try testing.expectEqual(clipboard.WriteResult.busy, write_result);
    try testing.expectEqual(@as(usize, 7), S.count);
    try testing.expectEqual(@as(usize, 5), S.last_contents_len);
    try testing.expectEqualStrings(
        "application/octet-stream",
        S.last_mimes[1][0..S.last_mime_lens[1]],
    );
    try testing.expectEqualSlices(u8, "a\x00b", S.last_data[1][0..S.last_data_lens[1]]);
    try testing.expectEqualStrings("image/png", S.last_mimes[4][0..S.last_mime_lens[4]]);
    try testing.expectEqualSlices(u8, "\x89PNG", S.last_data[4][0..S.last_data_lens[4]]);

    // Removing the callback takes effect immediately.
    try testing.expectEqual(Result.success, set(t, .clipboard_write, null));
    const after_remove = "\x1B]52;c;eA==\x1B\\";
    vt_write(t, after_remove, after_remove.len);
    try testing.expectEqual(@as(usize, 7), S.count);
}

test "clipboard_write without callback is unsupported and silent" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    // OSC 52 without a callback should not crash
    const seq = "\x1B]52;c;aGVsbG8=\x1B\\";
    vt_write(t, seq, seq.len);

    const handler = &t.?.stream.handler;
    const result = handler.effects.clipboard_write.?(handler, .{
        .location = .standard,
        .contents = &.{.{ .mime = "text/plain", .data = "hello" }},
    });
    try testing.expectEqual(clipboard.WriteResult.unsupported, result);
}

test "pwd_changed without callback is silent" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    // OSC 7 without a callback should not crash, but should still set the pwd
    const seq = "\x1B]7;file:///tmp\x1B\\";
    vt_write(t, seq, seq.len);
    try testing.expectEqualStrings("file:///tmp", zigTerminal(t).?.getPwd().?);
}

test "set size callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }

        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }

        fn sizeCb(_: Terminal, _: ?*anyopaque, out_size: *size_report.Size) callconv(lib.calling_conv) bool {
            out_size.* = .{
                .rows = 24,
                .columns = 80,
                .cell_width = 8,
                .cell_height = 16,
            };
            return true;
        }
    };
    defer S.deinit();

    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .size_cb, @ptrCast(&S.sizeCb)));

    // CSI 18 t — report text area size in characters
    vt_write(t, "\x1B[18t", 5);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1b[8;24;80t", S.last_data.?);
}

test "size without callback is silent" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    // CSI 18 t without a size callback should not crash
    vt_write(t, "\x1B[18t", 5);
}

test "set device_attributes callback primary" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }

        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }

        fn da(_: Terminal, _: ?*anyopaque, out: *Effects.CDeviceAttributes) callconv(lib.calling_conv) bool {
            out.* = .{
                .primary = .{
                    .conformance_level = 64,
                    .features = .{ 22, 52 } ++ .{0} ** 62,
                    .num_features = 2,
                },
                .secondary = .{
                    .device_type = 1,
                    .firmware_version = 10,
                    .rom_cartridge = 0,
                },
                .tertiary = .{ .unit_id = 0 },
            };
            return true;
        }
    };
    defer S.deinit();

    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .device_attributes, @ptrCast(&S.da)));

    // CSI c — primary DA
    vt_write(t, "\x1B[c", 3);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1b[?64;22;52c", S.last_data.?);
}

test "set device_attributes callback secondary" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }

        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }

        fn da(_: Terminal, _: ?*anyopaque, out: *Effects.CDeviceAttributes) callconv(lib.calling_conv) bool {
            out.* = .{
                .primary = .{
                    .conformance_level = 62,
                    .features = .{22} ++ .{0} ** 63,
                    .num_features = 1,
                },
                .secondary = .{
                    .device_type = 1,
                    .firmware_version = 10,
                    .rom_cartridge = 0,
                },
                .tertiary = .{ .unit_id = 0 },
            };
            return true;
        }
    };
    defer S.deinit();

    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .device_attributes, @ptrCast(&S.da)));

    // CSI > c — secondary DA
    vt_write(t, "\x1B[>c", 4);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1b[>1;10;0c", S.last_data.?);
}

test "set device_attributes callback tertiary" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }

        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }

        fn da(_: Terminal, _: ?*anyopaque, out: *Effects.CDeviceAttributes) callconv(lib.calling_conv) bool {
            out.* = .{
                .primary = .{
                    .conformance_level = 62,
                    .features = .{0} ** 64,
                    .num_features = 0,
                },
                .secondary = .{
                    .device_type = 1,
                    .firmware_version = 0,
                    .rom_cartridge = 0,
                },
                .tertiary = .{ .unit_id = 0xAABBCCDD },
            };
            return true;
        }
    };
    defer S.deinit();

    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .device_attributes, @ptrCast(&S.da)));

    // CSI = c — tertiary DA
    vt_write(t, "\x1B[=c", 4);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1bP!|AABBCCDD\x1b\\", S.last_data.?);
}

test "device_attributes without callback uses default" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }

        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
    };
    defer S.deinit();

    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));

    // Without setting a device_attributes callback, DA1 should return the default
    vt_write(t, "\x1B[c", 3);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1b[?62;22c", S.last_data.?);
}

test "device_attributes callback returns false uses default" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }

        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }

        fn da(_: Terminal, _: ?*anyopaque, _: *Effects.CDeviceAttributes) callconv(lib.calling_conv) bool {
            return false;
        }
    };
    defer S.deinit();

    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .device_attributes, @ptrCast(&S.da)));

    // Callback returns false, should use default response
    vt_write(t, "\x1B[c", 3);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1b[?62;22c", S.last_data.?);
}

test "set and get title" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    // No title set yet — should return empty string
    var title: lib.String = undefined;
    try testing.expectEqual(Result.success, get(t, .title, @ptrCast(&title)));
    try testing.expectEqual(@as(usize, 0), title.len);

    // Set title via option
    const hello: lib.String = .{ .ptr = "Hello", .len = 5 };
    try testing.expectEqual(Result.success, set(t, .title, @ptrCast(&hello)));

    try testing.expectEqual(Result.success, get(t, .title, @ptrCast(&title)));
    try testing.expectEqualStrings("Hello", title.ptr[0..title.len]);

    // Overwrite title
    const world: lib.String = .{ .ptr = "World", .len = 5 };
    try testing.expectEqual(Result.success, set(t, .title, @ptrCast(&world)));

    try testing.expectEqual(Result.success, get(t, .title, @ptrCast(&title)));
    try testing.expectEqualStrings("World", title.ptr[0..title.len]);

    // Clear title with NULL
    try testing.expectEqual(Result.success, set(t, .title, null));

    try testing.expectEqual(Result.success, get(t, .title, @ptrCast(&title)));
    try testing.expectEqual(@as(usize, 0), title.len);
}

test "set and get pwd" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    // No pwd set yet — should return empty string
    var pwd: lib.String = undefined;
    try testing.expectEqual(Result.success, get(t, .pwd, @ptrCast(&pwd)));
    try testing.expectEqual(@as(usize, 0), pwd.len);

    // Set pwd via option
    const home: lib.String = .{ .ptr = "/home/user", .len = 10 };
    try testing.expectEqual(Result.success, set(t, .pwd, @ptrCast(&home)));

    try testing.expectEqual(Result.success, get(t, .pwd, @ptrCast(&pwd)));
    try testing.expectEqualStrings("/home/user", pwd.ptr[0..pwd.len]);

    // Clear pwd with NULL
    try testing.expectEqual(Result.success, set(t, .pwd, null));

    try testing.expectEqual(Result.success, get(t, .pwd, @ptrCast(&pwd)));
    try testing.expectEqual(@as(usize, 0), pwd.len);
}

test "get title set via vt_write" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    // Set title via OSC 2
    vt_write(t, "\x1B]2;VT Title\x1B\\", 14);

    var title: lib.String = undefined;
    try testing.expectEqual(Result.success, get(t, .title, @ptrCast(&title)));
    try testing.expectEqualStrings("VT Title", title.ptr[0..title.len]);
}

test "title report requires explicit opt in" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |data| testing.allocator.free(data);
            last_data = null;
        }

        fn writePty(
            _: Terminal,
            _: ?*anyopaque,
            ptr: [*]const u8,
            len: usize,
        ) callconv(lib.calling_conv) void {
            if (last_data) |data| testing.allocator.free(data);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
    };
    S.last_data = null;
    defer S.deinit();

    try testing.expectEqual(
        Result.success,
        set(t, .write_pty, @ptrCast(&S.writePty)),
    );

    const set_title = "\x1B]2;echo vulnerable\x1B\\";
    const query_title = "\x1B[21t";
    vt_write(t, set_title, set_title.len);

    // WRITE_PTY alone must not enable the security-sensitive response.
    vt_write(t, query_title, query_title.len);
    try testing.expect(S.last_data == null);

    const enabled = true;
    try testing.expectEqual(Result.success, set(t, .title_report, &enabled));
    vt_write(t, query_title, query_title.len);
    try testing.expectEqualStrings(
        "\x1b]lecho vulnerable\x1b\\",
        S.last_data.?,
    );

    // NULL restores the secure default.
    S.deinit();
    try testing.expectEqual(Result.success, set(t, .title_report, null));
    vt_write(t, query_title, query_title.len);
    try testing.expect(S.last_data == null);
}

test "resize updates pixel dimensions" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    // Pixel geometry must still be applied when the cell dimensions match.
    try testing.expectEqual(Result.success, resize(t, 80, 24, 9, 18));

    const zt = t.?.terminal;
    try testing.expectEqual(@as(u32, 80 * 9), zt.width_px);
    try testing.expectEqual(@as(u32, 24 * 18), zt.height_px);
}

test "resize pixel overflow saturates" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    try testing.expectEqual(Result.success, resize(t, 100, 40, std.math.maxInt(u32), std.math.maxInt(u32)));

    const zt = t.?.terminal;
    try testing.expectEqual(std.math.maxInt(u32), zt.width_px);
    try testing.expectEqual(std.math.maxInt(u32), zt.height_px);
}

test "resize disables synchronized output" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const zt = t.?.terminal;
    zt.modes.set(.synchronized_output, true);

    // The terminal-level reset must run even if grid work is unnecessary.
    try testing.expectEqual(Result.success, resize(t, 80, 24, 9, 18));
    try testing.expect(!zt.modes.get(.synchronized_output));
}

test "resize sends in-band size report" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }

        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
    };
    defer S.deinit();

    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));

    // Enable in-band size reports (mode 2048)
    t.?.terminal.modes.set(.in_band_size_reports, true);

    try testing.expectEqual(Result.success, resize(t, 100, 40, 9, 18));

    // Expected: \x1B[48;rows;cols;height_px;width_pxt
    // height_px = 40*18 = 720, width_px = 100*9 = 900
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1B[48;40;100;720;900t", S.last_data.?);
}

test "resize no size report without mode 2048" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const S = struct {
        var called: bool = false;
        fn writePty(_: Terminal, _: ?*anyopaque, _: [*]const u8, _: usize) callconv(lib.calling_conv) void {
            called = true;
        }
    };
    S.called = false;

    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));

    // in_band_size_reports is off by default
    try testing.expectEqual(Result.success, resize(t, 100, 40, 9, 18));
    try testing.expect(!S.called);
}

test "resize in-band report without write_pty callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    // Enable mode 2048 but don't set a write_pty callback — should not crash
    t.?.terminal.modes.set(.in_band_size_reports, true);
    try testing.expectEqual(Result.success, resize(t, 100, 40, 9, 18));
}

test "resize null terminal" {
    try testing.expectEqual(Result.invalid_value, resize(null, 100, 40, 9, 18));
}

test "resize zero cols" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    try testing.expectEqual(Result.invalid_value, resize(t, 0, 40, 9, 18));
}

test "resize zero rows" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    try testing.expectEqual(Result.invalid_value, resize(t, 100, 0, 9, 18));
}

test "grid_ref out of bounds" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    var out_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.invalid_value, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 100, .y = 0 } },
    }, &out_ref));
}

test "set and get color_foreground" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    // Initially unset
    var rgb: color.RGB.C = undefined;
    try testing.expectEqual(Result.no_value, get(t, .color_foreground, @ptrCast(&rgb)));

    // Set a value
    const fg: color.RGB.C = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC };
    try testing.expectEqual(Result.success, set(t, .color_foreground, @ptrCast(&fg)));
    try testing.expectEqual(Result.success, get(t, .color_foreground, @ptrCast(&rgb)));
    try testing.expectEqual(fg, rgb);

    // Clear with null
    try testing.expectEqual(Result.success, set(t, .color_foreground, null));
    try testing.expectEqual(Result.no_value, get(t, .color_foreground, @ptrCast(&rgb)));
}

test "set and get color_background" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    var rgb: color.RGB.C = undefined;
    try testing.expectEqual(Result.no_value, get(t, .color_background, @ptrCast(&rgb)));

    const bg: color.RGB.C = .{ .r = 0x11, .g = 0x22, .b = 0x33 };
    try testing.expectEqual(Result.success, set(t, .color_background, @ptrCast(&bg)));
    try testing.expectEqual(Result.success, get(t, .color_background, @ptrCast(&rgb)));
    try testing.expectEqual(bg, rgb);

    try testing.expectEqual(Result.success, set(t, .color_background, null));
    try testing.expectEqual(Result.no_value, get(t, .color_background, @ptrCast(&rgb)));
}

test "set and get color_cursor" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    var rgb: color.RGB.C = undefined;
    try testing.expectEqual(Result.no_value, get(t, .color_cursor, @ptrCast(&rgb)));

    const cur: color.RGB.C = .{ .r = 0xFF, .g = 0x00, .b = 0x88 };
    try testing.expectEqual(Result.success, set(t, .color_cursor, @ptrCast(&cur)));
    try testing.expectEqual(Result.success, get(t, .color_cursor, @ptrCast(&rgb)));
    try testing.expectEqual(cur, rgb);

    try testing.expectEqual(Result.success, set(t, .color_cursor, null));
    try testing.expectEqual(Result.no_value, get(t, .color_cursor, @ptrCast(&rgb)));
}

test "set and get color_palette" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    // Get default palette
    var palette: color.PaletteC = undefined;
    try testing.expectEqual(Result.success, get(t, .color_palette, @ptrCast(&palette)));
    try testing.expectEqual(color.default[0].cval(), palette[0]);

    // Set custom palette
    var custom: color.PaletteC = color.paletteCval(&color.default);
    custom[0] = .{ .r = 0x12, .g = 0x34, .b = 0x56 };
    try testing.expectEqual(Result.success, set(t, .color_palette, @ptrCast(&custom)));
    try testing.expectEqual(Result.success, get(t, .color_palette, @ptrCast(&palette)));
    try testing.expectEqual(custom[0], palette[0]);

    // Reset with null restores default
    try testing.expectEqual(Result.success, set(t, .color_palette, null));
    try testing.expectEqual(Result.success, get(t, .color_palette, @ptrCast(&palette)));
    try testing.expectEqual(color.default[0].cval(), palette[0]);
}

test "get color default vs effective with override" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const zt = t.?.terminal;
    var rgb: color.RGB.C = undefined;

    // Set defaults
    const fg: color.RGB.C = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC };
    const bg: color.RGB.C = .{ .r = 0x11, .g = 0x22, .b = 0x33 };
    const cur: color.RGB.C = .{ .r = 0xFF, .g = 0x00, .b = 0x88 };
    try testing.expectEqual(Result.success, set(t, .color_foreground, @ptrCast(&fg)));
    try testing.expectEqual(Result.success, set(t, .color_background, @ptrCast(&bg)));
    try testing.expectEqual(Result.success, set(t, .color_cursor, @ptrCast(&cur)));

    // Simulate OSC overrides
    const override: color.RGB = .{ .r = 0x00, .g = 0x00, .b = 0x00 };
    zt.colors.foreground.override = override;
    zt.colors.background.override = override;
    zt.colors.cursor.override = override;

    // Effective returns override
    try testing.expectEqual(Result.success, get(t, .color_foreground, @ptrCast(&rgb)));
    try testing.expectEqual(override.cval(), rgb);
    try testing.expectEqual(Result.success, get(t, .color_background, @ptrCast(&rgb)));
    try testing.expectEqual(override.cval(), rgb);
    try testing.expectEqual(Result.success, get(t, .color_cursor, @ptrCast(&rgb)));
    try testing.expectEqual(override.cval(), rgb);

    // Default returns original
    try testing.expectEqual(Result.success, get(t, .color_foreground_default, @ptrCast(&rgb)));
    try testing.expectEqual(fg, rgb);
    try testing.expectEqual(Result.success, get(t, .color_background_default, @ptrCast(&rgb)));
    try testing.expectEqual(bg, rgb);
    try testing.expectEqual(Result.success, get(t, .color_cursor_default, @ptrCast(&rgb)));
    try testing.expectEqual(cur, rgb);
}

test "get color default returns no_value when unset" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    var rgb: color.RGB.C = undefined;
    try testing.expectEqual(Result.no_value, get(t, .color_foreground_default, @ptrCast(&rgb)));
    try testing.expectEqual(Result.no_value, get(t, .color_background_default, @ptrCast(&rgb)));
    try testing.expectEqual(Result.no_value, get(t, .color_cursor_default, @ptrCast(&rgb)));
}

test "get color_palette_default vs current" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const zt = t.?.terminal;

    // Set a custom default palette
    var custom: color.PaletteC = color.paletteCval(&color.default);
    custom[0] = .{ .r = 0x12, .g = 0x34, .b = 0x56 };
    try testing.expectEqual(Result.success, set(t, .color_palette, @ptrCast(&custom)));

    // Simulate OSC override on index 0
    zt.colors.palette.set(0, .{ .r = 0xFF, .g = 0xFF, .b = 0xFF });

    // Current palette returns the override
    var palette: color.PaletteC = undefined;
    try testing.expectEqual(Result.success, get(t, .color_palette, @ptrCast(&palette)));
    try testing.expectEqual(color.RGB.C{ .r = 0xFF, .g = 0xFF, .b = 0xFF }, palette[0]);

    // Default palette returns the original
    try testing.expectEqual(Result.success, get(t, .color_palette_default, @ptrCast(&palette)));
    try testing.expectEqual(custom[0], palette[0]);
}

test "set color sets dirty flag" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const zt = t.?.terminal;
    zt.flags.dirty.palette = false;

    const fg: color.RGB.C = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF };
    try testing.expectEqual(Result.success, set(t, .color_foreground, @ptrCast(&fg)));
    try testing.expect(zt.flags.dirty.palette);
}

test "set glyph protocol disables APC handling and clears glossary" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    const register = "\x1B_25a1;r;cp=e0a0;AAAAAAAAAAAAAA==\x1B\\";
    vt_write(t, register, register.len);
    try testing.expect(t.?.terminal.glyph_glossary.contains(0xE0A0));

    const disabled = false;
    try testing.expectEqual(Result.success, set(t, .glyph_protocol, @ptrCast(&disabled)));
    try testing.expect(!t.?.stream.handler.apc_handler.enabled.contains(.glyph));
    try testing.expect(!t.?.terminal.glyph_glossary.contains(0xE0A0));

    vt_write(t, register, register.len);
    try testing.expect(!t.?.terminal.glyph_glossary.contains(0xE0A0));

    const enabled = true;
    try testing.expectEqual(Result.success, set(t, .glyph_protocol, @ptrCast(&enabled)));
    vt_write(t, register, register.len);
    try testing.expect(t.?.terminal.glyph_glossary.contains(0xE0A0));
}

test "get_multi success" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    var cols: u16 = 0;
    var rows: u16 = 0;
    var written: usize = 0;

    const keys = [_]TerminalData{ .cols, .rows };
    var values = [_]?*anyopaque{ @ptrCast(&cols), @ptrCast(&rows) };
    try testing.expectEqual(Result.success, get_multi(t, keys.len, &keys, &values, &written));
    try testing.expectEqual(keys.len, written);
    try testing.expectEqual(80, cols);
    try testing.expectEqual(24, rows);
}

test "get_multi error sets out_written" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);

    var cols: u16 = 0;
    var written: usize = 99;

    const keys = [_]TerminalData{ .cols, .invalid };
    var values = [_]?*anyopaque{ @ptrCast(&cols), @ptrCast(&cols) };
    try testing.expectEqual(Result.invalid_value, get_multi(t, keys.len, &keys, &values, &written));
    try testing.expectEqual(1, written);
    try testing.expectEqual(80, cols);
}

test "get_multi null keys returns invalid_value" {
    var cols: u16 = 0;
    var values = [_]?*anyopaque{@ptrCast(&cols)};
    try testing.expectEqual(Result.invalid_value, get_multi(null, 1, null, &values, null));
}
