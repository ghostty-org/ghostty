const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const mem = @import("mem.zig");
const Terminal = ghostty_vt.Terminal;
const TerminalStream = ghostty_vt.TerminalStream;
const Handler = @FieldType(TerminalStream, "handler");

/// Use a single global allocator for simplicity and to avoid heap
/// allocation overhead in the fuzzer. The allocator is backed by a fixed
/// buffer, and every fuzz input resets the bump pointer to the start.
var fuzz_alloc: mem.FuzzAllocator(64 * 1024 * 1024) = .{};

/// Stub implementations for `Handler.Effects` and `Handler.unknown_sequence`.
/// By default, `t.vtStream()` initializes `effects` to `.readonly` (all null),
/// which causes `stream_terminal.zig` to return early before decoding payloads,
/// formatting query replies, or updating protocol state.
const callbacks = struct {
    fn writePty(_: *Handler, data: []const u8) void {
        std.mem.doNotOptimizeAway(data);
    }
    fn noop(_: *Handler) void {}
    fn desktopNotification(_: *Handler, n: ghostty_vt.StreamAction.ShowDesktopNotification) void {
        std.mem.doNotOptimizeAway(n);
    }
    fn dragAndDrop(_: *Handler, e: ghostty_vt.kitty.dnd.Event) void {
        std.mem.doNotOptimizeAway(e);
    }
    fn colorScheme(_: *Handler) ?ghostty_vt.device_status.ColorScheme {
        return .dark;
    }
    fn deviceAttributes(_: *Handler) ghostty_vt.device_attributes.Attributes {
        return .{};
    }
    fn enquiry(_: *Handler) []const u8 {
        return "ghostty";
    }
    fn size(_: *Handler) ?ghostty_vt.size_report.Size {
        return .{
            .rows = 24,
            .columns = 80,
            .cell_width = 8,
            .cell_height = 16,
        };
    }
    fn progressReport(_: *Handler, r: ghostty_vt.osc.Command.ProgressReport) void {
        std.mem.doNotOptimizeAway(r);
    }
    fn programStatus(_: *Handler, r: ghostty_vt.osc.Command.ProgramStatus.Report) void {
        std.mem.doNotOptimizeAway(r);
    }
    fn semanticPrompt(_: *Handler, e: Handler.SemanticPrompt) void {
        std.mem.doNotOptimizeAway(e);
    }
    fn resizeWindow(_: *Handler, r: Handler.ResizeWindow) void {
        std.mem.doNotOptimizeAway(r);
    }
    fn clipboardWrite(_: *Handler, w: ghostty_vt.clipboard.Write) void {
        std.mem.doNotOptimizeAway(w);
    }
    fn clipboardRead(_: *Handler, r: ghostty_vt.clipboard.Read) void {
        std.mem.doNotOptimizeAway(r);
    }
    fn xtversion(_: *Handler) []const u8 {
        return "ghostty";
    }
    fn renderHold(_: *Handler, held: bool) void {
        std.mem.doNotOptimizeAway(held);
    }
    fn unknownSequence(_: *Handler, seq: Handler.UnknownSequence) void {
        std.mem.doNotOptimizeAway(seq);
    }
};

pub export fn zig_fuzz_init() callconv(.c) void {
    fuzz_alloc.init();
}

pub export fn zig_fuzz_test(
    buf: [*]const u8,
    len: usize,
) callconv(.c) void {
    // Do not test zero-length input paths.
    if (len == 0) return;

    fuzz_alloc.reset();
    const alloc = fuzz_alloc.allocator();
    const input = buf[0..len];

    // Allocate a terminal; if we run out of fixed-buffer space just
    // skip this input (not a bug, just a very large allocation).
    var t = Terminal.init(ghostty_vt.TinyIo.init.io(), alloc, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback_bytes = 100,
    }) catch return;
    defer t.deinit(alloc);

    var stream: TerminalStream = t.vtStream();
    defer stream.deinit();

    // Populate handler callbacks and opt-in reporting flags so query/response
    // and effect-handling paths in stream_terminal.zig are exercised.
    stream.handler.title_report = true;
    stream.handler.xt_checksum_report = true;
    stream.handler.terminfo_name = "xterm-ghostty";
    stream.handler.unknown_sequence = &callbacks.unknownSequence;
    stream.handler.effects = .{
        .write_pty = &callbacks.writePty,
        .bell = &callbacks.noop,
        .desktop_notification = &callbacks.desktopNotification,
        .drag_and_drop = &callbacks.dragAndDrop,
        .color_scheme = &callbacks.colorScheme,
        .device_attributes = &callbacks.deviceAttributes,
        .enquiry = &callbacks.enquiry,
        .size = &callbacks.size,
        .title_changed = &callbacks.noop,
        .pwd_changed = &callbacks.noop,
        .progress_report = &callbacks.progressReport,
        .program_status = &callbacks.programStatus,
        .semantic_prompt = &callbacks.semanticPrompt,
        .reset = &callbacks.noop,
        .resize_window = &callbacks.resizeWindow,
        .clipboard_write = &callbacks.clipboardWrite,
        .clipboard_read = &callbacks.clipboardRead,
        .xtversion = &callbacks.xtversion,
        .render_hold = &callbacks.renderHold,
    };

    // Use the first byte as a mode bitfield.
    const mode = input[0];
    const data = input[1..];

    // Bit 1 toggles unknown APC/OSC sequence capture and truncation.
    if (mode & 0b10 != 0) {
        stream.handler.apc_handler.unknown_max_bytes = 256;
        stream.parser.osc_parser.unknown_max_bytes = 256;
    }

    // Bit 0 selects between the slice and scalar paths so both code
    // paths get exercised by the fuzzer.
    if (mode & 0b01 == 0) {
        // Slice path — exercises SIMD fast-path if enabled
        stream.nextSlice(data);
    } else {
        // Scalar path — exercises byte-at-a-time UTF-8 decoding
        for (data) |byte| stream.next(byte);
    }
}
